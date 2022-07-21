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
require_relative "TaskManager"
require_relative "FileUtil"
require "FileUtils"
require_relative "StrUtil"
require_relative "ExecUtil"
require 'shellwords'

class ApkUtil
	DEF_XMLPRINTER = ENV["PATH_AXMLPRINTER"] ? ENV["PATH_AXMLPRINTER"] : "AXMLPrinter2.jar"
	DEF_DEX2JAR = ENV["PATH_DEX2JAR"] ? ENV["PATH_DEX2JAR"] : "d2j-dex2jar.sh"
	DEF_DISASM = ENV["PATH_JAVADISASM"] ? ENV["PATH_JAVADISASM"] : "class2java.sh"

	def self.extractArchive(archivePath, outputDir, specificFile=nil)
		exec_cmd = "unzip -o -qq  #{Shellwords.escape(archivePath)}"
		exec_cmd = "#{exec_cmd} #{Shellwords.escape(specificFile)}" if specificFile
		exec_cmd = "#{exec_cmd} -d #{Shellwords.escape(outputDir)} 2>/dev/null"

		ExecUtil.execCmd(exec_cmd)
	end

	def self.convertedFromBinaryXmlToPlainXml(binaryXmlPath, outputPath)
		exec_cmd = "java -jar #{Shellwords.escape(DEF_XMLPRINTER)} #{Shellwords.escape(binaryXmlPath)} > #{Shellwords.escape(outputPath)} 2>/dev/null"

		ExecUtil.execCmd(exec_cmd, ".", false)
	end

	def self.convertDex2Jar(dexPath, outputJarDir)
		outputJarDir = outputJarDir.slice( 0, outputJarDir.length-1 ) if outputJarDir.end_with?("/")

		filename = FileUtil.getFilenameFromPath(dexPath)
		pos = filename.rindex(".dex")
		filename = filename.slice(0, pos) if pos
		outputJarPath = "#{outputJarDir}/#{filename}-dex2jar.jar"

		exec_cmd = "#{Shellwords.escape(DEF_DEX2JAR)} --force #{Shellwords.escape(dexPath)} -o #{Shellwords.escape(outputJarPath)}"
		ExecUtil.execCmd(exec_cmd, ".")

		return outputJarPath
	end

	def self.disassembleClass(classesDir, outputPath, execTimeout)
		exec_cmd = ""
		if DEF_DISASM.include?("jad") then
			exec_cmd = "#{Shellwords.escape(DEF_DISASM)} -r -o -sjava -d#{Shellwords.escape(outputPath)} **/*.class"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, classesDir, execTimeout)
		else
			exec_cmd = "#{Shellwords.escape(DEF_DISASM)} -o #{Shellwords.escape(outputPath)} #{Shellwords.escape(classesDir)}"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, ".", execTimeout)
		end
	end

	DEF_TOMBSTONE="tombstone.txt"
	DEF_TOMBSTONE_FILESIZE="fileSize"
	DEF_TOMBSTONE_APKNAME="apkName"
	DEF_TOMBSTONE_SIGNATURE="signature"

	def self.getSignatureFingerprint(apkPath)
		result = nil
		if File.exist?(apkPath) then
			exec_cmd = "list-apk-signature.rb #{Shellwords.escape(apkPath)}"
			result = ExecUtil.getExecResultEachLine(exec_cmd)
			if result.length then
				result = result[0].to_s
			end
		end
		return result
	end

	def self.dumpTombstone(apkPath, tombstonePath, enableSign=false)
		if File.exist?(apkPath) then
			buf = []
			buf << "#{DEF_TOMBSTONE_FILESIZE}:#{File.size(apkPath)}"
			buf << "#{DEF_TOMBSTONE_APKNAME}:#{FileUtil.getFilenameFromPath(apkPath)}"
			buf << "#{DEF_TOMBSTONE_SIGNATURE}:#{getSignatureFingerprint(apkPath)}" if enableSign
			FileUtil.writeFile("#{tombstonePath}/#{DEF_TOMBSTONE}", buf)
		end
	end
end

class ApkDisasmExecutor < TaskAsync
	DEF_ANDROID_MANIFEST = "AndroidManifest.xml"
	DEF_CLASSES = "classes*.dex"
	DEF_CLASSES_REGEXP = "classes.*\.dex"
	DEF_RESOURCES = "res/*"
	DEF_SOURCE = "src"

	def initialize(apkName, options)
		super("ApkDisasmExecutor #{apkName}")
		@apkName = apkName
		@verbose = options[:verbose]
		@outputDirectory = "#{options[:outputDirectory]}/#{FileUtil.getFilenameFromPathWithoutExt(@apkName)}"

		@manifest = options[:manifest]
		@resource = options[:resource]
		@source = options[:source]
		@tombstone = options[:tombstone]
		@extractAll = options[:extractAll]

		@execTimeout = options[:execTimeout]
		@enableSign = options[:tombstoneSign]
	end

	def _convertBinaryXmlToPlain(binaryXmlPath)
		basePath = FileUtil.getDirectoryFromPath(binaryXmlPath)
		filename = FileUtil.getFilenameFromPath(binaryXmlPath)
		tmpOut1 = "#{basePath}/#{filename}"
		tmpOut2 = "#{basePath}/plain-#{filename}"
		ApkUtil.convertedFromBinaryXmlToPlainXml(tmpOut1, tmpOut2)
		FileUtils.rm_f(tmpOut1) if File.exist?(tmpOut1)
		FileUtils.mv(tmpOut2, tmpOut1) if File.exist?(tmpOut2)
	end

	def execute
		FileUtil.ensureDirectory(@outputDirectory)

		# extract the .apk
		if @extractAll then
			ApkUtil.extractArchive(@apkName, @outputDirectory)
		end

		if @manifest || @resource || @source || @tombstone then
			# convert binary AndroidManifest.xml to plain xml
			if @manifest then
				ApkUtil.extractArchive(@apkName, @outputDirectory, DEF_ANDROID_MANIFEST) if !@extractAll
				manifestPath="#{@outputDirectory}/#{DEF_ANDROID_MANIFEST}"
				if File.exist?(manifestPath) then
					_convertBinaryXmlToPlain(manifestPath)
				end
			end

			# convert binary xml in res/ to plain xml
			if @resource then
				ApkUtil.extractArchive(@apkName, @outputDirectory, DEF_RESOURCES) if !@extractAll
				resourcePath="#{@outputDirectory}/res"
				if FileTest.directory?(resourcePath) then
					binaryXmlPaths = FileUtil.getRegExpFilteredFiles(resourcePath, "\.xml$")
					binaryXmlPaths.each do |aBinaryXml|
						_convertBinaryXmlToPlain(aBinaryXml)
					end
				end
			end

			# create stat info. as tombstone
			if @tombstone then
				ApkUtil.dumpTombstone(@apkName, @outputDirectory, @enableSign)
			end

			# disassemble .class to .java and file output
			if @source then
				ApkUtil.extractArchive(@apkName, @outputDirectory, DEF_CLASSES) if !@extractAll
				classesDexPath = "#{@outputDirectory}/#{DEF_CLASSES}"
				classDexPaths = []
				FileUtil.iteratePath( FileUtil.getDirectoryFromPath( classesDexPath ), DEF_CLASSES_REGEXP, classDexPaths, true, false )
				classDexPaths.each do | aClassDexPath |
					convertedClassesDexPath = ApkUtil.convertDex2Jar( aClassDexPath, @outputDirectory )
					if File.exist?( convertedClassesDexPath ) then
						tmpExtractedClassesPath = "#{@outputDirectory}/#{FileUtil.getFilenameFromPathWithoutExt( convertedClassesDexPath )}"
						ApkUtil.extractArchive( convertedClassesDexPath, tmpExtractedClassesPath )
						FileUtils.rm_f( convertedClassesDexPath )
						if FileTest.directory?( tmpExtractedClassesPath ) then
							disassembledSrc = "#{@outputDirectory}/#{DEF_SOURCE}"
							ApkUtil.disassembleClass( tmpExtractedClassesPath, disassembledSrc, @execTimeout )
							FileUtils.rm_rf( tmpExtractedClassesPath )
						end
					end
					FileUtils.rm_rf( aClassDexPath ) if !@extractAll
				end
			end
		end

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
	:tombstoneSign=>false,
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

	opts.on("-s", "--enableSource", "Enable to disassemble src from classes.dex") do
		options[:source] = true
	end

	opts.on("-m", "--enableManifest", "Enable to extract plain AndroidManifest.xml") do
		options[:manifest] = true
	end

	opts.on("-r", "--enableResource", "Enable to extract plain xml in res/") do
		options[:resource] = true
	end

	opts.on("-t", "--enableTombstone", "Enable to output Tombstone") do
		options[:tombstone] = true
	end

	opts.on("-t", "--enableApkSignatureTombstone", "Enable to output apk signature to Tombstone") do
		options[:tombstoneSign] = true
	end

	opts.on("-x", "--extractAll", "Enable to extract all in the apk") do
		options[:extractAll] = true
		options[:manifest] = true
		options[:resource] = true
		options[:tombstone] = true
		options[:tombstoneSign] = true
		options[:source] = true
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

