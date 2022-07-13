#!/usr/bin/ruby

# Copyright 2022 hidenory
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'optparse'
require 'date'
require 'rexml/document'
require "./TaskManager"
require "./FileUtil"
require "./StrUtil"
require "./ExecUtil"
require 'shellwords'


class ApkDisasmExecutor < TaskAsync
	DEF_ANDROID_MANIFEST = "AndroidManifest.xml"
	DEF_CLASSES = "classes.dex"
	DEF_RESOURCES = "res/*"
	DEF_SOURCE = "src"

	def initialize(apkName, options)
		super("ApkDisasmExecutor #{apkName}")
		@apkName = apkName
		@verbose = options[:verbose]
		@outputDirectory = "#{options[:outputDirectory]}/#{FileUtil.getFilenameFromPath(@apkName)}"

		@manifest = options[:manifest]
		@resource = options[:resource]
		@source = options[:source]
		@tombstone = options[:tombstone]
		@extractAll = options[:extractAll]

		@execTimeout = options[:execTimeout]
	end

	def execute
		FileUtil.ensureDirectory(@outputDirectory)

		# extract the .apk

		# convert binary AndroidManifest.xml to plain xml

		# convert binary xml in res/ to plain xml

		# create stat info. as tombstone

		# disassemble .class to .cjava and file output
		_doneTask()
	end
end


#---- main --------------------------
options = {
	:verbose => false,
	:outputDirectory => ".",
	:manifest => false,
	:resource => false,
	:source => false,
	:extractAll => false,
	:tombstone=>false,
	:execTimeout=>10*60, # 10 minutes
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

OptionParser.new do |opts|
	opts.banner = "Usage: anApkPath or apksStoredDirectory [options]"

	opts.on("-j", "--numOfThreads=", "Specify number of threads (default:#{options[:numOfThreads]})") do |numOfThreads|
		options[:numOfThreads] = numOfThreads.to_i
		options[:numOfThreads] = 1 if !options[:numOfThreads]
	end

	opts.on("-o", "--outputDir=", "Specify output directory (default:#{options[:outputDirectory]})") do |outputDirectory|
		options[:outputDirectory] = outputDirectory
	end

	opts.on("-v", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!

if (ARGV.length < 1) then
	exit(-1)
end

if !options[:manifest] && !options[:resource] && !options[:source] && !options[:tombstone] && !options[:extractAll] then
	exit(-1)
end

apkPaths = []
if FileTest.directory?(ARGV[0]) then
	apkPaths = FileUtil.getRegExpFilteredFiles(ARGV[0], "\.apk$")
elsif File.exist?(ARGV[0]) then
	apkPaths << ARGV[0]
else
	puts "Please specify an apk path or directory storing apks"
end

FileUtil.ensureDirectory(options[:outputDirectory])

taskMan = TaskManagerAsync.new( options[:numOfThreads].to_i )
apkPaths.each do |aTarget|
	taskMan.addTask( ApkDisasmExecutor.new(
		aTarget, 
		options,
		)
	)
end
taskMan.executeAll()
taskMan.finalize()

