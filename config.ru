$LOAD_PATH.unshift File.dirname(__FILE__)

require 'rubygems'
require 'bundler'

Bundler.require

require 'neovigator'

$stdout.sync = true

run Neovigator
