######################################################################
# This file is imported from the rubygems project.
# DO NOT make modifications in this repo. They _will_ be reverted!
# File a patch instead and assign it to Ryan Davis or Eric Hodel.
######################################################################

require "test/rubygems/gemutilities"
require 'rubygems/commands/lock_command'

class TestGemCommandsLockCommand < RubyGemTestCase

  def setup
    super

    @a1 = quick_gem 'a', '1'
    @b1 = quick_gem 'b', '1' do |s|
      s.add_runtime_dependency 'a'
    end

    @d1 = quick_gem 'd', '1' do |s|
      s.add_runtime_dependency 'z'
    end

    @cmd = Gem::Commands::LockCommand.new
  end

  def test_execute
    @cmd.handle_options %w[b-1]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<-EXPECTED
require 'rubygems'
gem 'b', '= 1'
gem 'a', '= 1'
    EXPECTED

    assert_equal expected, @ui.output
    assert_equal '', @ui.error
  end

  def test_execute_missing_dependency
    @cmd.handle_options %w[d-1]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<-EXPECTED
require 'rubygems'
gem 'd', '= 1'
# Unable to satisfy 'z (>= 0, runtime)' from currently installed gems
    EXPECTED

    assert_equal expected, @ui.output
    assert_equal '', @ui.error
  end

  def test_execute_strict
    @cmd.handle_options %w[c-1 --strict]

    e = assert_raises Gem::Exception do
      use_ui @ui do
        @cmd.execute
      end
    end

    assert_equal 'Could not find gem c-1, try using the full name', e.message
  end

end

