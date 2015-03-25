#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
$: << File.expand_path(File.dirname(__FILE__))
require 'pigeonhole.rb'

run Sinatra::Application

