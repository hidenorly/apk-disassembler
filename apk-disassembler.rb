#!/usr/bin/ruby

# Copyright 2022, 2023 hidenory
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
require "fileutils"
require_relative "StrUtil"
require_relative "ExecUtil"
require 'shellwords'
require 'set'

class LibUtil
	def self.reportExportedSymbols(libPath, outputFilePath)
		exec_cmd = "objdump -T --demangle #{Shellwords.escape(libPath)} > #{Shellwords.escape(outputFilePath)}"

		ExecUtil.execCmd(exec_cmd, ".", false)
	end
end

class JavaDisasm
	DEF_DISASM = ENV["PATH_JAVADISASM"] ? ENV["PATH_JAVADISASM"] : "class2java.sh"

	def self.isRequiredDexToJar(disAsmType=nil)
		return false if DEF_DISASM.include?("jadx") || disAsmType=="jadx"
		return true
	end

	def self.disassembleClass(classesDir, outputPath, execTimeout, classesDexPath=nil, disAsmType=nil)
		exec_cmd = ""
		if DEF_DISASM.include?("jadx") || disAsmType=="jadx" then
			classFiles = []
			classFiles = [classesDexPath] if classesDexPath && File.exist?(classesDexPath)
			if classFiles.empty? then
				classFiles = FileUtil.getRegExpFilteredFiles(classesDir, "\.class")
			end
			FileUtil.ensureDirectory(outputPath)
			classFiles.each do |aClassFile|
				exec_cmd = "#{Shellwords.escape(DEF_DISASM)} -ds #{Shellwords.escape(File.expand_path(outputPath))} #{Shellwords.escape(File.expand_path(aClassFile))}"
				ExecUtil.execCmd(exec_cmd, FileUtil.getDirectoryFromPath(aClassFile), true)
			end
		elsif DEF_DISASM.include?("jad") || disAsmType=="jad"  then
			exec_cmd = "#{Shellwords.escape(DEF_DISASM)} -r -o -sjava -d#{Shellwords.escape(outputPath)} **/*.class"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, classesDir, execTimeout)
		else
			exec_cmd = "#{Shellwords.escape(DEF_DISASM)} -o #{Shellwords.escape(outputPath)} #{Shellwords.escape(classesDir)}"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, ".", execTimeout)
		end
	end
end


class ApkUtil
	DEF_XMLPRINTER = ENV["PATH_AXMLPRINTER"] ? ENV["PATH_AXMLPRINTER"] : "AXMLPrinter2.jar"
	DEF_DEX2JAR = ENV["PATH_DEX2JAR"] ? ENV["PATH_DEX2JAR"] : "d2j-dex2jar.sh"

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

	DEF_TOMBSTONE="tombstone.txt"
	DEF_TOMBSTONE_FILESIZE="fileSize"
	DEF_TOMBSTONE_APKNAME="apkName"
	DEF_TOMBSTONE_APKPATH="apkPath"
	DEF_TOMBSTONE_SIGNATURE="signature"
	DEF_TOMBSTONE_ABI="abi"

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

	DEF_DEPLOY_BASE_PATH = [
		"system/",
		"system_ext/",
		"product/",
		"oem/",
		"vendor/",
		"odm/",
	]

	def self.getApkDeployPath(apkPath)
		result = apkPath

		DEF_DEPLOY_BASE_PATH.each do | aDeployBasePath |
			pos = apkPath.index( aDeployBasePath )
			if pos then
				result = apkPath.slice( pos, apkPath.length )
				break
			end
		end

		return result
	end

	def self.dumpTombstone(apkPath, tombstonePath, enableSign=false, enableApkPath=false, supportedABIs=[])
		if File.exist?(apkPath) then
			buf = []
			buf << "#{DEF_TOMBSTONE_FILESIZE}:#{File.size(apkPath)}"
			buf << "#{DEF_TOMBSTONE_APKNAME}:#{FileUtil.getFilenameFromPath(apkPath)}"
			buf << "#{DEF_TOMBSTONE_SIGNATURE}:#{getSignatureFingerprint(apkPath)}" if enableSign
			buf << "#{DEF_TOMBSTONE_APKPATH}:#{getApkDeployPath(apkPath)}" if enableApkPath
			buf << "#{DEF_TOMBSTONE_ABI}:#{ supportedABIs.join(",") }" if !supportedABIs.empty?

			FileUtil.writeFile("#{tombstonePath}/#{DEF_TOMBSTONE}", buf)
		end
	end
end

class ApkDisasmExecutor < TaskAsync
	DEF_ANDROID_MANIFEST = "AndroidManifest.xml"
	DEF_CLASSES = "classes*.dex"
	DEF_CLASSES_REGEXP = "classes.*\.dex"
	DEF_LIBS_PATH = ["lib", "lib64"]
	DEF_LIBS_REGEXP = ".*\.so"
	DEF_RESOURCES = "res/*"
	DEF_SOURCE = "src"

	def initialize(apkName, options)
		super("ApkDisasmExecutor #{apkName}")
		@apkName = apkName
		@verbose = options[:verbose]
		@outputDirectory = "#{options[:outputDirectory]}/#{FileUtil.getFilenameFromPathWithoutExt(@apkName)}"

		@extractAll = options[:extractAll]
		@execTimeout = options[:execTimeout]

		@manifest = options[:manifest]
		@resource = options[:resource]
		@source = options[:source]
		@tombstone = options[:tombstone]
		@enableSign = options[:tombstoneSign]
		@enableApkPath = options[:tombstoneApkPath]
		@enableAbi = options[:tombstoneAbi]
		@enableLib = options[:library]
		@abi = options[:abi].to_s.split(",")
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

	def _getCompatibleAbi( path )
		result = nil
		path = path.to_s
		@abi.each do |anAbi|
			pos = path.index( anAbi )
			if pos then
				result = path.slice( pos, anAbi.length )
				break
			end
		end
		return result
	end

	def _isCompatibleAbi( path )
		result = _getCompatibleAbi( path )
		return result ? true : false
	end

	def execute
		FileUtil.ensureDirectory(@outputDirectory)

		# extract the .apk
		if @extractAll then
			ApkUtil.extractArchive(@apkName, @outputDirectory)
		end

		if @manifest || @resource || @source || @tombstone || @enableLib then
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

			supportedABIs = Set.new()
			# extact lib
			if @enableLib || @enableAbi then
				if !@extractAll then
					DEF_LIBS_PATH.each do | aLibPath |
						outputPath = "#{aLibPath}/*"
						ApkUtil.extractArchive(@apkName, @outputDirectory, outputPath)
					end
				end
				DEF_LIBS_PATH.each do | aLibPath |
					libPath = "#{@outputDirectory}/#{aLibPath}"
					if FileTest.directory?(libPath) then
						soPaths = FileUtil.getRegExpFilteredFiles(libPath, DEF_LIBS_REGEXP)
						soPaths.each do |aSoPath|
							if _isCompatibleAbi( aSoPath ) then
								supportedABIs.add( _getCompatibleAbi( aSoPath ) )
								if @enableLib then
									reportPath = "#{FileUtil.getDirectoryFromPath(aSoPath)}/#{FileUtil.getFilenameFromPathWithoutExt(aSoPath)}-symbols.txt"
									LibUtil.reportExportedSymbols( aSoPath, reportPath )
								end
							else
								# this is not intended abi's shared object
								FileUtils.rm_f( aSoPath ) if !@extractAll
							end
						end
					end
				end
			end

			# create stat info. as tombstone
			if @tombstone then
				ApkUtil.dumpTombstone(@apkName, @outputDirectory, @enableSign, @enableApkPath, @enableAbi ? supportedABIs.to_a : [])
			end

			# disassemble .class to .java and file output
			if @source then
				isRequiredDexToJar = JavaDisasm.isRequiredDexToJar()
				disassembledSrc = "#{@outputDirectory}/#{DEF_SOURCE}"
				ApkUtil.extractArchive(@apkName, @outputDirectory, DEF_CLASSES) if !@extractAll
				classesDexPath = "#{@outputDirectory}/#{DEF_CLASSES}"
				classDexPaths = []
				FileUtil.iteratePath( FileUtil.getDirectoryFromPath( classesDexPath ), DEF_CLASSES_REGEXP, classDexPaths, true, false )
				classDexPaths.each do | aClassDexPath |
					if isRequiredDexToJar then
						convertedClassesDexPath = ApkUtil.convertDex2Jar( aClassDexPath, @outputDirectory )
						if File.exist?( convertedClassesDexPath ) then
							tmpExtractedClassesPath = "#{@outputDirectory}/#{FileUtil.getFilenameFromPathWithoutExt( convertedClassesDexPath )}"
							ApkUtil.extractArchive( convertedClassesDexPath, tmpExtractedClassesPath )
							FileUtils.rm_f( convertedClassesDexPath )
							if FileTest.directory?( tmpExtractedClassesPath ) then
								JavaDisasm.disassembleClass( tmpExtractedClassesPath, disassembledSrc, @execTimeout, aClassDexPath )
								FileUtils.rm_rf( tmpExtractedClassesPath )
							end
						end
					else
						# For JADX like disassembler (android .dex format acceptable case, not require normal java .jar)
						JavaDisasm.disassembleClass( nil, disassembledSrc, @execTimeout, aClassDexPath )
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
	:extractAll => false,
	:execTimeout => 10*60, # 10 minutes
	:manifest => false,
	:resource => false,
	:source => false,
	:tombstone => false,
	:tombstoneSign => false,
	:tombstoneApkPath => false,
	:tombstoneAbi => false,
	:library => false,
	:abi => "arm64-v8a,armeabi-v7a,x86,x86_64",
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

	opts.on("-f", "--enableApkSignatureTombstone", "Enable to output apk signature to Tombstone") do
		options[:tombstoneSign] = true
		options[:tombstone] = true
	end

	opts.on("-p", "--enableApkPathTombstone", "Enable to output apk path to Tombstone") do
		options[:tombstoneApkPath] = true
		options[:tombstone] = true
	end

	opts.on("", "--enableAbiTombstone", "Enable to output supported ABI to Tombstone") do
		options[:tombstoneAbi] = true
		options[:tombstone] = true
	end

	opts.on("-l", "--enableLibAnalysis", "Enable to native library analysis") do
		options[:library] = true
	end

	opts.on("-a", "--abi=", "Specify abi for enableLibAnalysis default:#{options[:abi]}") do |abi|
		options[:abi] = abi
	end

	opts.on("-e", "--execTimeout=", "Specify timeout for external commands (default:#{options[:execTimeout]}) [sec]") do |execTimeout|
		options[:execTimeout] = execTimeout.to_i
	end

	opts.on("-x", "--extractAll", "Enable to extract all in the apk") do
		options[:extractAll] = true
		options[:manifest] = true
		options[:resource] = true
		options[:tombstone] = true
		options[:tombstoneSign] = true
		options[:tombstoneApkPath] = true
		options[:tombstoneAbi] = true
		options[:source] = true
		options[:library] = true
	end
end.parse!

if (ARGV.length < 1) then
	exit(-1)
end

if !options[:manifest] && !options[:resource] && !options[:source] && !options[:tombstone] && !options[:extractAll] && !options[:library] then
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
