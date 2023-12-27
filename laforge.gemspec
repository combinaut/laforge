$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "laforge/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "laforge"
  s.version     = LaForge::VERSION
  s.authors     = ["Nicholas Jakobsen"]
  s.email       = ["nicholas@combinaut.ca"]
  s.homepage    = "https://github.com/combinaut/laforge"
  s.summary     = "LaForge is a gem that makes it easy to build records using data from several data sources"
  s.description = "LaForge is a gem that makes it easy to build records using data from several data sources. It aims to facilitate management of which data sources a record is assembled from, and to perform the actual data assembly in order to output a record."
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]

  s.add_dependency 'rails', '~> 6.0'

  s.add_development_dependency 'combustion', '~> 1.3'
  s.add_development_dependency 'mysql2', '~> 0.5.5'
  s.add_development_dependency 'rspec-rails', '~> 3.7'
end
