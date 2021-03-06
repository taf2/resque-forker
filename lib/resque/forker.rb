require 'fcntl'
require "logger"
require "resque"
require "syslog"
require 'resque/forker/version'

module Resque
  # Loading Rails, the application and all its dependencies takes significant time
  # and eats up memory. We keep startup time manageable by loading the application
  # once and forking the worker processes. When using REE, this will also keep
  # memory usage low. Note that we can't reuse connections and file handles in
  # child processes, so no saving on opening database connections, etc.
  #
  # To use this library, wrap your setup and teardown blocks: 
  #   Resque.setup do |forker|
  #     $:.unshift File.dirname(__FILE__) + "/.."
  #     require "config/environment"
  #     ActiveRecord::Base.connection.disconnect!
  #     forker.logger = Rails.logger
  #     forker.user "nobody", "nobody"
  #     forker.workload = ["*"] * 8
  #     forker.options.interval = 1
  #   end
  #   Resque.before_first_fork do
  #     ActiveRecord::Base.establish_connection
  #   end
  #
  # Most libraries cannot share connections between child processes, you want to
  # close these in the parent process (during setup) and reopen connections for
  # each worker when it needs it to process a job (during after_work). This
  # example shows how to do that for ActiveRecord, you will need to do the same
  # for other libraries, e.g. MongoMapper, Vanity. 
  #
  # All the forking action is handled by a single call:
  #   # Three workers, processing all queues
  #   Resque.fork! :workload=>["*"] * 3
  #
  # The workload is specified as an array of lists of queues, that way you can
  # decide how many workers to fork (length of the array) and give each worker
  # different set of queues to work with. For example, to have four workers
  # processing import queue, and only two of these also processing export queue:
  #
  #   forker.workload = ["import,export", "import"] * 2
  #
  # Once the process is up and running, you control it by sending signals:
  # - kill -QUIT -- Quit gracefully
  # - kill -TERM -- Terminate immediately
  # - kill -USR2 -- Suspend all workers (e.g when running rake db:migrate)
  # - kill -CONT -- Resume suspended workers
  # - kill -HUP -- Shutdown and restart
  #
  # The HUP signal will wait for all existing jobs to complete, run the teardown
  # block, and reload the script with the same environment and arguments. It will
  # reload the application, the libraries, and of course any configuration changes
  # in this script (e.g. changes to the workload).
  #
  # The reloaded process keeps the same PID so you can use it with upstart:
  #   reload workers
  # The upstart script could look something like this:
  #   start on runlevel [2345]
  #   stop on runlevel [06]
  #   chdir /var/app/current
  #   env RAILS_ENV=production
  #   exec script/workers
  #   respawn
  class Forker
    attr_reader :pid
    attr_accessor :reexec_pid
    # allow a USR2 + QUIT to upgrade without worker downtime...
    # see: unicorn/lib/unicorn/http_server.rb
    START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      0 => $0.dup,
    }
    # We favor ENV['PWD'] since it is (usually) symlink aware for Capistrano
    # and like systems
    START_CTX[:cwd] = begin
      a = File.stat(pwd = ENV['PWD'])
      b = File.stat(Dir.pwd)
      a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
    rescue
      Dir.pwd
    end


    Options = Struct.new(:verbose, :very_verbose, :interval, :terminate, :pidfile)

    def initialize(options = nil)
      self.reexec_pid = 0
      options ||= {}
      @logger = options[:logger] || Logger.new($stderr)
      @workload = options[:workload] || ["*"]
      @options = Options[*options.values_at(*Options.members)]
      @children = []
      begin
        require "system_timer"
        @timeout = SystemTimer.method(:timeout_after)
      rescue NameError, LoadError
        require "timeout"
        @timeout = method(:timeout)
      end
    end

    # Workload is an array of queue sets, one entry per workers (so four entries
    # if you want four workers). Each entry is comma-separated queue names.
    attr_accessor :workload

    # Defaults to stderr, but you may want to point this at Rails logger.
    attr_accessor :logger

    # Most options can be changed from the Resque.setup hook. See Options.
    attr_reader :options

    # Run and never return.
    def run
      @logger.info "** Running as #{Process.pid}"
      setup_signals
      if setup = Resque.setup
        @logger.info "** Loading application ..."
        setup.call self
      end
      reap_children
      @logger.info "** Forking workers"
      self.pid = @options[:pidfile]
      Resque.teardown do|forker|
        File.unlink(pid) if pid && File.exist?(pid)
      end
      @logger.info "** Dropped pidfile: #$$ -> #{pid}"
      enable_gc_optimizations
      # Serious forking action.
      @workload.each do |queues|
        @children << fork { run_worker queues }
      end
    rescue
      @logger.error "** Failed to load application: #{$!.message}"
      @logger.error $!.backtrace.join("\n")
    ensure
      # Sleep forever.
      sleep 5 while true
    end

    # Change ownership of this process.
    def user(user, group)
      uid = Etc.getpwnam(user).uid
      gid = Etc.getgrnam(group).gid
      if Process.euid != uid || Process.egid != gid
        Process.initgroups user, gid
        Process::GID.change_privilege gid
        Process::UID.change_privilege uid
      end
    end 

  protected

    # Setup signal handlers.
    def setup_signals
      # Stop gracefully
      trap :QUIT do
        @logger.info "** Received Quit ..."
        stop
        exit
      end
      # Pause/continue processing
      trap(:USR1) { dump }
      trap(:USR2) { Process.kill :USR2, *@children }
      trap(:CONT) { Process.kill :CONT, *@children }
      # Reincarnate. Stop children, and reload binary (application and all)
      # while keeping same PID.
      trap :HUP do
        @logger.info "** Reincarnating ..."
        stop
        reexec
      end
      # Terminate quickly
      trap(:TERM) { shutdown! }
      trap(:INT) { shutdown! }
    end

    def pid=(path)
      STDERR.puts "dropping pid to #{path}"
      # TODO: should do more to be safe see unicorn
      if path
        begin
          @logger.info "** dropping pid #$$ -> #{path} **"
          fp = begin
            tmp = "#{File.dirname(path)}/#{rand}.#$$"
            File.open(tmp, File::RDWR|File::CREAT|File::EXCL, 0644)
          rescue Errno::EEXIST
            retry
          end
          fp.syswrite("#$$\n")
          File.rename(fp.path, path)
        ensure
          fp.close if fp
        end
      end
      @pid = path
    end

    # reexecutes the START_CTX with a new binary
    # see: unicorn/lib/unicorn/http_server.rb#reexec
    def reexec
      if reexec_pid > 0
        begin
          Process.kill(0, reexec_pid)
          STDERR.puts "reexec-ed child already running PID:#{reexec_pid}"
          return
        rescue Errno::ESRCH
          reexec_pid = 0
        end
      end

      if pid
        old_pid = "#{pid}.oldbin"
        begin
          self.pid = old_pid  # clear the path for a new pid file
        rescue ArgumentError
          STDERR.puts "old PID:#{valid_pid?(old_pid)} running with " \
                       "existing pid=#{old_pid}, refusing rexec"
          return
        rescue => e
          STDERR.puts "error writing pid=#{old_pid} #{e.class} #{e.message}"
          return
        end
      end

      reexec_pid = fork do
        Dir.chdir(START_CTX[:cwd])
        cmd = [ START_CTX[0] ].concat(START_CTX[:argv])

        # avoid leaking FDs we don't know about, but let before_exec
        # unset FD_CLOEXEC, if anything else in the app eventually
        # relies on FD inheritence.
        (3..1024).each do |io|
          #next if listener_fds.include?(io)
          io = IO.for_fd(io) rescue next
          io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
        end
        STDOUT.puts "executing #{cmd.inspect} (in #{Dir.pwd})"
        #before_exec.call(self)
        exec(*cmd)
      end
      #proc_name 'master (old)'
    end

    # Enables GC Optimizations if you're running REE.
    # http://www.rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
    def enable_gc_optimizations
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
    end

    # Run and never return.
    def run_worker(queues)
      worker = Resque::Worker.new(*queues.split(","))
      worker.verbose = options.verbose
      worker.very_verbose = options.very_verbose
      worker.work(options.interval || 5) # interval, will block
    end

    # Stop child processes and run any teardown action.
    def stop(gracefully = true)
      @logger.info "** Quitting ..."
      @children.each do |pid|
        begin
          Process.kill gracefully ? :QUIT : :TERM, pid
          sleep 0.1
        rescue Errno::ESRCH
        end
      end
      reap_children
      if teardown = Resque.teardown
        @timeout.call options.terminate || 5 do
          begin
            teardown.call self
          rescue Exception
          end
        end
      end
      @logger.info "** Good night"
    end

    # Eat up zombies.
    def reap_children
      loop do
        wpid, status = Process.waitpid2(0, Process::WNOHANG)
        wpid or break
      end
      @children.clear
    rescue Errno::ECHILD
    end

    # When stop is not good enough.
    def shutdown!
      @logger.info "** Terminating"
      stop false
      exit!
    end

    def dump
      Syslog.open "resque-forker" unless Syslog.opened?
      Syslog.notice "STATUS:"
      for key, value in Resque.info.to_a.sort_by { |i| i[0].to_s }
        Syslog.notice "%20s: %s" % [key, value]
      end
      Syslog.notice "QUEUES:"
      for queue in Resque.queues.sort_by { |q| q.to_s }
        Syslog.notice "%20s: %d" % [queue, Resque.size(queue)]
      end
      Syslog.notice "WORKERS:"
      for worker in (workers = Resque.workers.sort_by { |w| w.to_s })
        Syslog.notice "%40s: %s" % [worker, worker.state]
      end
      Syslog.notice "There are no registered workers" if workers.empty?
    rescue
      Syslog.err $!
    end

  end

  
  # Specify what needs to be done to setup the application. This is the place
  # to load Rails or do anything expensive. For example:
  #   Resque.setup do
  #     require File.dirname(__FILE__) + "/../config/environment"
  #     ActiveRecord.disconnect
  #   end
  def setup(&block)
    block ? (@setup = block) : @setup
  end

  # Do this before exiting or before reloading.
  def teardown(&block)
    block ? (@teardown = block) : @teardown
  end

  # Forks workers to take care of the workload.
  #
  # The workload is an array of queue names, one entry for each worker. For
  # example, if you want to run four workers processing all queues.
  #   Resque.fork! ["*"] * 4
  # If you want four workers, all of which will be processing imports, but
  # only two processing exports:
  #   Resque.fork! ["import", "import,export"] * 2
  #
  # Options are:
  # - :logger -- Which Logger to use (default logger to stdout)
  # - :interval -- Processing interval (default to 5 seconds)
  # - :terminate -- Timeout running teardown block (default to 5 seconds)
  # - :verbose -- Be verbose.
  # - :very_verbose -- Make :verbose look quiet.
  # - :workload -- The initial workload.
  #
  # You can also set these options from the Resque.setup hook.
  def fork!(options = nil)
    Resque::Forker.new(options).run
  end

  # Have Resque console show the command/arguments.
  alias :info_without_forker :info
  def info
    hash = info_without_forker
    hash[:script] = ([$0] + ARGV).map { |a| a[/[\s"]/] ? a.inspect : a }.join(" ")
    hash
  end
  
end
