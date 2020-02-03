require 'bundler/setup'
require 'pg'
require 'pg/instrumentation'
require 'opentracing_test_tracer'

RSpec.configure do |config|

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
