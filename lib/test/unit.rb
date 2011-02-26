# test/unit compatibility layer using minitest.

require 'minitest/unit'
require 'test/unit/assertions'
require 'test/unit/testcase'
require 'optparse'

module Test
  module Unit
    TEST_UNIT_IMPLEMENTATION = 'test/unit compatibility layer using minitest'

    module RunCount
      @@run_count = 0

      def self.have_run?
        @@run_count.nonzero?
      end

      def run(*)
        @@run_count += 1
        super
      end

      def run_once
        return if have_run?
        return if $! # don't run if there was an exception
        yield
      end
      module_function :run_once
    end

    module Options
      def initialize(*, &block)
        @init_hook = block
        @options = nil
        super(&nil)
      end

      def option_parser
        @option_parser ||= OptionParser.new
      end

      def process_args(args = [])
        return @options if @options
        orig_args = args.dup
        options = {}
        opts = option_parser
        setup_options(opts, options)
        opts.parse!(args)
        orig_args -= args
        args = @init_hook.call(args, options) if @init_hook
        non_options(args, options)
        @help = orig_args.map { |s| s =~ /[\s|&<>$()]/ ? s.inspect : s }.join " "
        @options = options
        @opts = @options = options
        if @options[:parallel]
          @files = args
          @args = orig_args
        end
      end

      private
      def setup_options(opts, options)
        opts.separator 'minitest options:'
        opts.version = MiniTest::Unit::VERSION

        opts.on '-h', '--help', 'Display this help.' do
          puts opts
          exit
        end

        opts.on '-s', '--seed SEED', Integer, "Sets random seed" do |m|
          options[:seed] = m.to_i
        end

        opts.on '-v', '--verbose', "Verbose. Show progress processing files." do
          options[:verbose] = true
          self.verbose = options[:verbose]
        end

        opts.on '-n', '--name PATTERN', "Filter test names on pattern." do |a|
          options[:filter] = a
        end

        opts.on '--jobs-status [TYPE]', "Show status of jobs every file; Disabled when --jobs isn't specified." do |type|
          options[:job_status] = true
          options[:job_status_type] = type.to_sym if type
        end

        opts.on '-j N', '--jobs N', "Allow run tests with N jobs at once" do |a|
          if /^t/ =~ a
            options[:testing] = true # For testing
            options[:parallel] = a[1..-1].to_i
          else
            options[:parallel] = a.to_i
          end
        end

        opts.on '--no-retry', "Don't retry running testcase when --jobs specified" do
          options[:no_retry] = true
        end

        opts.on '--ruby VAL', "Path to ruby; It'll have used at -j option" do |a|
          options[:ruby] = a.split(/ /).reject(&:empty?)
        end
      end

      def non_options(files, options)
        begin
          require "rbconfig"
        rescue LoadError
          warn "#{caller(1)[0]}: warning: Parallel running disabled because can't get path to ruby; run specify with --ruby argument"
          options[:parallel] = nil
        else
          options[:ruby] ||= RbConfig.ruby
        end

        true
      end
    end

    module GlobOption
      include Options

      def setup_options(parser, options)
        super
        parser.on '-b', '--basedir=DIR', 'Base directory of test suites.' do |dir|
          options[:base_directory] = dir
        end
        parser.on '-x', '--exclude PATTERN', 'Exclude test files on pattern.' do |pattern|
          (options[:reject] ||= []) << pattern
        end
      end

      def non_options(files, options)
        paths = [options.delete(:base_directory), nil].uniq
        if reject = options.delete(:reject)
          reject_pat = Regexp.union(reject.map {|r| /#{r}/ })
        end
        files.map! {|f|
          f = f.tr(File::ALT_SEPARATOR, File::SEPARATOR) if File::ALT_SEPARATOR
          [*(paths if /\A\.\.?(?:\z|\/)/ !~ f), nil].uniq.any? do |prefix|
            if prefix
              path = f.empty? ? prefix : "#{prefix}/#{f}"
            else
              next if f.empty?
              path = f
            end
            if !(match = Dir["#{path}/**/test_*.rb"]).empty?
              if reject
                match.reject! {|n|
                  n[(prefix.length+1)..-1] if prefix
                  reject_pat =~ n
                }
              end
              break match
            elsif !reject or reject_pat !~ f and File.exist? path
              break path
            end
          end or
            raise ArgumentError, "file not found: #{f}"
        }
        files.flatten!
        super(files, options)
      end
    end

    module LoadPathOption
      include Options

      def setup_options(parser, options)
        super
        parser.on '-Idirectory', 'Add library load path' do |dirs|
          dirs.split(':').each { |d| $LOAD_PATH.unshift d }
        end
      end
    end

    module GCStressOption
      def setup_options(parser, options)
        super
        parser.on '--[no-]gc-stress', 'Set GC.stress as true' do |flag|
          options[:gc_stress] = flag
        end
      end

      def non_options(files, options)
        if options.delete(:gc_stress)
          MiniTest::Unit::TestCase.class_eval do
            oldrun = instance_method(:run)
            define_method(:run) do |runner|
              begin
                gc_stress, GC.stress = GC.stress, true
                oldrun.bind(self).call(runner)
              ensure
                GC.stress = gc_stress
              end
            end
          end
        end
        super
      end
    end

    module RequireFiles
      def non_options(files, options)
        return false if !super
        result = false
        files.each {|f|
          d = File.dirname(path = File.expand_path(f))
          unless $:.include? d
            $: << d
          end
          begin
            require path unless options[:parallel]
            result = true
          rescue LoadError
            puts "#{f}: #{$!}"
          end
        }
        result
      end
    end

    class Runner < MiniTest::Unit
      include Test::Unit::Options
      include Test::Unit::GlobOption
      include Test::Unit::LoadPathOption
      include Test::Unit::GCStressOption
      include Test::Unit::RunCount

      class Worker
        def self.launch(ruby,args=[])
          i,o = IO.pipe("ASCII-8BIT") # worker o>|i> master
          j,k = IO.pipe("ASCII-8BIT") # worker <j|<k master
          k.sync = true
          pid = spawn(*ruby,
                      "#{File.dirname(__FILE__)}/unit/parallel.rb",
                      *args, out: o, in: j)
          [o,j].each(&:close)
          new(in: k, out: i, pid: pid, status: :waiting)
        end

        def initialize(h={})
          @worker = h
          @hooks = {}
        end

        def run(task,type)
          @worker[:file] = File.basename(task).gsub(/\.rb/,"")
          @worker[:real_file] = task
          begin
            @worker[:loadpath] ||= []
            @worker[:in].puts "loadpath #{[Marshal.dump($:-@worker[:loadpath])].pack("m").gsub("\n","")}"
            @worker[:loadpath] = $:.dup
            @worker[:in].puts "run #{task} #{type}"
            @worker[:status] = :prepare
          rescue Errno::EPIPE
            dead
          rescue IOError
            raise unless ["stream closed","closed stream"].include? $!.message
            dead
          end
        end

        def hook(id,&block)
          @hooks[id] ||= []
          @hooks[id] << block
          self
        end

        def read
          ((self[:status] == :quit) ? self[:out].read : self[:out].gets).chomp
        end

        def [](k); @worker[k]; end
        def []=(k,v); @worker[k]=v; end

        def dead(*additional)
          @worker[:status] = :quit
          @worker[:in].close
          @worker[:out].close

          call_hook(:dead,*additional)
        end

        def to_s
          if self[:file]
            "#{self[:pid]}=#{self[:file]}"
          else
            "#{self[:pid]}:#{self[:status].to_s.ljust(7)}"
          end
        end

        private

        def call_hook(id,*additional)
          @hooks[id] ||= []
          @hooks[id].each{|hook| hook[self,additional] }
          self
        end

      end

      class << self; undef autorun; end

      undef options

      def options
        @optss ||= (@options||{}).merge(@opts)
      end

      @@stop_auto_run = false
      def self.autorun
        at_exit {
          Test::Unit::RunCount.run_once {
            exit(Test::Unit::Runner.new.run(ARGV) || true)
          } unless @@stop_auto_run
        } unless @@installed_at_exit
        @@installed_at_exit = true
      end

      def after_worker_down(worker, e=nil, c=1)
        return unless @opts[:parallel]
        return if @interrupt
        if e
          b = e.backtrace
          warn "#{b.shift}: #{e.message} (#{e.class})"
          STDERR.print b.map{|s| "\tfrom #{s}"}.join("\n")
        end
        @need_quit = true
        warn ""
        warn "Some worker was crashed. It seems ruby interpreter's bug"
        warn "or, a bug of test/unit/parallel.rb. try again without -j"
        warn "option."
        warn ""
        STDERR.flush
        exit c
      end

      def jobs_status
        return unless @opts[:job_status]
        puts "" unless @opts[:verbose]
        status_line = @workers.map(&:to_s).join(" ")
        if @opts[:job_status_type] == :replace
          @terminal_width ||= %x{stty size 2>/dev/null}.split[1].to_i.nonzero? \
                          ||  %x{tput cols 2>/dev/null}.to_i.nonzero? \
                          ||  80
          @jstr_size ||= 0
          del_jobs_status
          STDOUT.flush
          print status_line[0...@terminal_width]
          STDOUT.flush
          @jstr_size = status_line.size > @terminal_width ? \
                         @terminal_width : status_line.size
        else
          puts status_line
        end
      end

      def del_jobs_status
        return unless @opts[:job_status_type] == :replace && @jstr_size
        print "\r"+" "*@jstr_size+"\r"
      end

      def after_worker_dead(worker)
        return unless @opts[:parallel]
        return if @interrupt
        @workers.delete(worker)
        @dead_workers << worker
        @ios = @workers.map{|w| w[:out] }
      end

      def _run_parallel suites, type, result
        begin
          # Require needed things for parallel running
          require 'thread'
          require 'timeout'
          @tasks = @files.dup # Array of filenames.
          @need_quit = false
          @dead_workers = []  # Array of dead workers.
          @warnings = []
          shutting_down = false
          rep = [] # FIXME: more good naming

          # Array of workers.
          @workers = @opts[:parallel].times.map {
            begin
            worker = Worker.launch(@opts[:ruby],@args)
            worker.hook(:dead) do |w,info|
              after_worker_dead w
              after_worker_down w, *info unless info.empty?
            end
            worker
            rescue Exception; puts "#{$!.class}: #{$!.message}\n#{$!.backtrace}"
            end
          }

          # Thread: watchdog
          watchdog = Thread.new do
            while stat = Process.wait2
              break if @interrupt # Break when interrupt
              w = (@workers + @dead_workers).find{|x| stat[0] == x[:pid] }.dup
              next unless w
              unless w[:status] == :quit
                # Worker down
                w.dead(nil, stat[1].to_i)
              end
            end
          end

          @workers_hash = Hash[@workers.map {|w| [w[:out],w] }] # out-IO => worker
          @ios = @workers.map{|w| w[:out] } # Array of worker IOs

          while _io = IO.select(@ios)[0]
            break unless _io.each do |io|
              break if @need_quit
              worker = @workers_hash[io]
              case worker.read
              when /^okay$/
                worker[:status] = :running
                jobs_status
              when /^ready$/
                worker[:status] = :ready
                if @tasks.empty?
                  break unless @workers.find{|x| x[:status] == :running }
                else
                  worker.run(@tasks.shift, type)
                end

                jobs_status
              when /^done (.+?)$/
                r = Marshal.load($1.unpack("m")[0])
                result << r[0..1]
                rep    << {file: worker[:real_file],
                           report: r[2], result: r[3], testcase: r[5]}
                $:.push(*r[4]).uniq!
              when /^p (.+?)$/
                del_jobs_status
                print $1.unpack("m")[0]
                jobs_status if @opts[:job_status_type] == :replace
              when /^after (.+?)$/
                @warnings << Marshal.load($1.unpack("m")[0])
              when /^bye (.+?)$/
                after_worker_down worker, Marshal.load($1.unpack("m")[0])
              when /^bye$/
                if shutting_down
                  after_worker_dead worker
                else
                  after_worker_down worker
                end
              end
              break if @need_quit
            end
          end
        rescue Interrupt => e
          @interrupt = e
          return result
        ensure
          shutting_down = true

          watchdog.kill if watchdog
          @workers.each do |worker|
            begin
              timeout(1) do
                worker[:in].puts "quit"
              end
            rescue Errno::EPIPE
            rescue Timeout::Error
            end
            [:in,:out].each { |name| worker[name].close }
          end
          begin
            timeout(0.2*@workers.size) do
              Process.waitall
            end
          rescue Timeout::Error
            @workers.each do |worker|
              begin
                Process.kill(:KILL,worker[:pid])
              rescue Errno::ESRCH; end
            end
          end

          if @interrupt || @opts[:no_retry]
            rep.each do |r|
              report.push(*r[:report])
            end
            @errors += rep.map{|x| x[:result][0] }.inject(:+)
            @failures += rep.map{|x| x[:result][1] }.inject(:+)
            @skips += rep.map{|x| x[:result][2] }.inject(:+)
          elsif @need_quit
            rep.each do |r|
              report.push(*r[:report])
              @errors += r[:result][0]
              @failures += r[:result][1]
              @skips += r[:result][2]
            end
          else
            puts ""
            puts "Retrying..."
            puts ""
            @options = @opts
            rep.each do |r|
              if r[:testcase] && r[:file] && !r[:report].empty?
                require r[:file]
                _run_suite(eval(r[:testcase]),type)
              else
                report.push(*r[:report])
                @errors += r[:result][0]
                @failures += r[:result][1]
                @skips += r[:result][2]
              end
            end
          end
          if @warnings
            warn ""
            ary = []
            @warnings.reject! do |w|
              r = ary.include?(w[1].message)
              ary << w[1].message
              r
            end
            @warnings.each do |w|
              warn "#{w[0]}: #{w[1].message} (#{w[1].class})"
            end
            warn ""
          end
        end
      end

      def _run_suites suites, type
        @interrupt = nil
        result = []
        if @opts[:parallel]
          _run_parallel suites, type, result
        else
          suites.each {|suite|
            begin
              result << _run_suite(suite, type)
            rescue Interrupt => e
              @interrupt = e
              break
            end
          }
        end
        result
      end

      def status(*args)
        result = super
        raise @interrupt if @interrupt
        result
      end
    end

    class AutoRunner
      class Runner < Test::Unit::Runner
        include Test::Unit::RequireFiles
      end

      attr_accessor :to_run, :options

      def initialize(force_standalone = false, default_dir = nil, argv = ARGV)
        @runner = Runner.new do |files, options|
          options[:base_directory] ||= default_dir
          files << default_dir if files.empty? and default_dir
          @to_run = files
          yield self if block_given?
          files
        end
        @options = @runner.option_parser
        @argv = argv
      end

      def process_args(*args)
        @runner.process_args(*args)
        !@to_run.empty?
      end

      def run
        @runner.run(@argv) || true
      end

      def self.run(*args)
        new(*args).run
      end
    end
  end
end

Test::Unit::Runner.autorun
