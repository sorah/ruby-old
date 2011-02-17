require 'test/unit'

module Test                # :nodoc:
  module Unit              # :nodoc:
    class TestCase         # :nodoc:
      class << self; alias orig_inherited inherited; end
      def self.inherited x # :nodoc:
        orig_inherited x
        Test::Unit::Worker.suites << x
      end
    end
  end
end

module Test
  module Unit
    class Worker < Runner
      @@suites = []

      class << self
        def suites; @@suites; end
        undef autorun
      end
      
      alias orig_run_suite _run_suite
      undef _run_suite
      undef _run_suites

      def _run_suites suites, type
        suites.map do |suite|
          result = _run_suite(suite, type)
        end
      end

      def _run_suite(suite, type)
        r = report.dup
        orig_stdout = MiniTest::Unit.output
        i,o = IO.pipe
        MiniTest::Unit.output = o

        stdout = STDOUT.dup

        th = Thread.new do
          begin
            while buf = (self.verbose ? i.gets : i.read(5))
              stdout.puts "p #{[buf].pack("m").gsub("\n","")}"
            end
          rescue IOError; end
        end

        e, f, s = @errors, @failures, @skips

        result = orig_run_suite(suite, type)

        MiniTest::Unit.output = orig_stdout

        o.close
        i.close

        begin
          th.join
        rescue IOError
          raise unless ["stream closed","closed stream"].include? $!.message
        end

        result << (report - r)
        result << [@errors-e,@failures-f,@skips-s]
        result << ($: - @old_loadpath)

        STDOUT.puts "done #{[Marshal.dump(result)].pack("m").gsub("\n","")}"
        return result
      ensure
        MiniTest::Unit.output = orig_stdout
        o.close unless o.closed?
        i.close unless i.closed?
      end

      def run(args = [])
        process_args args
        @@stop_auto_run = true
        @opts = @options.dup

        STDOUT.sync = true
        STDOUT.puts "ready"
        Signal.trap(:INT,"IGNORE")


        @old_loadpath = []
        begin
          while buf = STDIN.gets
            case buf.chomp
            when /^loadpath (.+?)$/
              @old_loadpath = $:.dup
              $:.push(*Marshal.load($1.unpack("m")[0].force_encoding("ASCII-8BIT"))).uniq!
            when /^run (.+?) (.+?)$/
              puts "okay"

              stdin = STDIN.dup
              stdout = STDOUT.dup
              th = Thread.new do
                while puf = stdin.gets
                  if puf.chomp == "quit"
                    begin
                      stdout.puts "bye"
                    rescue Errno::EPIPE; end
                    exit 
                  end
                end
              end

              @options = @opts.dup
              @@suites = []
              require $1
              _run_suites @@suites, $2.to_sym

              STDIN.reopen(stdin)
              STDOUT.reopen(stdout)

              th.kill
              STDOUT.puts "ready"
            when /^quit$/
              begin
                STDOUT.puts "bye"
              rescue Errno::EPIPE; end
              exit
            end
          end
        rescue Exception => e
          unless e.kind_of?(SystemExit)
            b = e.backtrace
            warn "#{b.shift}: #{e.message} (#{e.class})"
            STDERR.print b.map{|s| "\tfrom #{s}"}.join("\n")
          end
          STDOUT.puts "bye #{[Marshal.dump(e)].pack("m").gsub("\n","")}"
          exit
        ensure
          stdin.close
        end
      end
    end
  end
end

Test::Unit::Worker.new.run(ARGV)
