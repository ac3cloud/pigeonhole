#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'pigeonhole.rb'

run Sinatra::Application
