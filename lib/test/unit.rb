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
 
        opts.on '--jobs-status', "Enable -v and show status of jobs every file; Disabled when --jobs isn't specified." do
          options[:job_status] = true
        end

        opts.on '-j N', '--jobs N', "Allow run tests with N jobs at once" do |a|
          options[:parallel] = a.to_i
          options[:verbose] = true
          self.verbose = options[:verbose]
        end

        opts.on '--ruby VAL', "Path to ruby; It'll have used at -j option" do |a|
          options[:ruby] = a
        end
      end

      def non_options(files, options)
        begin
          require "rbconfig"
        rescue LoadError
          warn "#{caller(1)[0]}: warning: Parallel running disabled because can't get path to ruby; run specify with --ruby argument"
          options[:parallel] = nil
        else
          options[:ruby] = RbConfig.ruby
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
      include Test::Unit::RequireFiles
      include Test::Unit::GlobOption
      include Test::Unit::LoadPathOption
      include Test::Unit::GCStressOption
      include Test::Unit::RunCount

      class << self; undef autorun; end
      @@stop_auto_run = false
      def self.autorun
        at_exit {
          Test::Unit::RunCount.run_once {
            exit(Test::Unit::Runner.new.run(ARGV) || true)
          } unless @@stop_auto_run
        } unless @@installed_at_exit
        @@installed_at_exit = true
      end

      def _run_suites suites, type
        @interrupt = nil
        result = []
        if @opts[:parallel]
          begin
            # Require needed things for parallel running
            require 'thread'
            require 'timeout'
            tasks = @files.dup # Array of filenames.
            queue = Queue.new  # Queue of workers which are ready.
            dead_workers = []  # Array of dead workers.

            # Array of workers.
            workers = @opts[:parallel].times.map do
              i,o = IO.pipe # worker o>|i> master
              j,k = IO.pipe # worker <j|<k master
              k.sync = true
              pid = spawn(*@opts[:ruby].split(/ /),File.dirname(__FILE__) +
                          "/unit/parallel.rb", *@args, out: o, in: j)
              [o,j].each{|io| io.close }
              {in: k, out: i, pid: pid, status: :waiting}
            end

            # Thread: watchdog
            watchdog = Thread.new do
              while stat = Process.wait2
                break if @interrupt # Break when interrupt
                w = (workers + dead_workers).find{|x| stat[0] == x[:pid] }.dup
                next unless w
                p w
                unless w[:status] == :quit
                  # Worker down
                  queue << nil
                  warn ""
                  warn "Some worker was crashed. It seems ruby interpreter's bug"
                  warn "or, a bug of test/unit/parallel.rb. try again without -j"
                  warn "option."
                  warn ""
                  exit stat[1].to_i
                end
              end
            end
            workers_hash = Hash[workers.map {|w| [w[:out],w] }] # out-IO => worker
            ios = workers.map{|w| w[:out] } # Array of worker IOs

            # Thread: IO Processor
            io_processor = Thread.new do
              while _io = IO.select(ios)[0]
                _io.each do |io|
                  a = workers_hash[io]
                  case ((a[:status] == :quit) ? io.read : io.gets).chomp
                  when /^okay$/ # Worker will run task
                    a[:status] = :running
                    puts workers.map{|x| "#{x[:pid]}:#{x[:status]}" }.join(" ") if @opts[:job_status]
                  when /^ready$/ # Worker is ready
                    a[:status] = :ready
                    if tasks.empty?
                      break
                    else
                      queue << a
                    end

                    puts workers.map{|x| "#{x[:pid]}:#{x[:status]}" }.join(" ") if @opts[:job_status]
                  when /^done (.+?)$/ # Worker ran a one of suites in a file
                    r = Marshal.load($1.unpack("m")[0])
                    # [result,result,report,$:]
                    result << r[0..1]
                    report.push(*r[2])
                    $:.push(*r[3]).uniq!
                  when /^p (.+?)$/ # Worker wanna print to STDOUT
                    print $1.unpack("m")[0]
                  when /^bye$/ # Worker will shutdown
                    a[:status] = :quit
                    a[:in].close
                    a[:out].close
                    workers.delete(a)
                    dead_workers << a
                    ios = workers.map{|w| w[:out] }
                  end
                end
              end
            end

            while queue.empty?; end
            while task = tasks.shift
              worker = queue.shift
              break unless worker
              next if worker[:status] != :ready
              begin
                worker[:loadpath] ||= []
                worker[:in].puts "loadpath #{[Marshal.dump($:-worker[:loadpath])].pack("m").gsub("\n","")}"
                worker[:loadpath] = $:.dup
                worker[:in].puts "run #{task} #{type}"
              rescue IOError
                raise unless ["stream closed","closed stream"].include? $!.message
                worker[:status] = :quit
                worker[:in].close
                worker[:out].close
                workers.delete(worker)
                dead_workers << worker
                ios = workers.map{|w| w[:out] }
              end
            end
            while workers.find{|x| x[:status] == :running }; end
          rescue Interrupt => e
            @interrupt = e
            return
          ensure
            watchdog.kill
            io_processor.kill
            workers.each do |w|
              begin
                w[:in].puts "quit"
              rescue Errno::EPIPE; end
              [:in,:out].each do |x|
                w[x].close
              end
            end
            begin
              timeout(0.2*workers.size) do
                Process.waitall
              end
            rescue Timeout::Error
              workers.each do |w|
                begin
                  Process.kill(:KILL,w[:pid])
                rescue Errno::ESRCH; end
              end
            end
          end
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
