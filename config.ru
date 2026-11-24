require 'rubygems'
require 'bundler'

Bundler.require :default, :development

Combustion.initialize! :active_record, :action_controller
run Combustion::Application
