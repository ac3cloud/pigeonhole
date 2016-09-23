#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'pigeonhole.rb'

run Sinatra::Application
