begin
  require 'bundler/setup'
rescue LoadError
  puts 'You must `gem install bundler` and `bundle install` to run rake tasks'
end

APP_RAKEFILE = File.expand_path("../spec/internal/Rakefile", __FILE__)

Bundler::GemHelper.install_tasks


# Add Rspec tasks
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task :default => :spec
