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
require_relative "Reporter"
require 'shellwords'

class AndroidAnalyzeUtil
	def self.parseAndroidManifest(manifestPath)
		result = {
			:packageName => nil,
			:sharedUserId => nil,
			:targetSdkVersion => 0,
			:persistent => false,
			:usesPermissions => [],
			:usesLibraries => [],
			:usesFeatures => [],
			:broadcastIntents => [],
		}
		manifestPath = "#{manifestPath}/AndroidManifest.xml" if !File.exist?(manifestPath)

		if File.exist?(manifestPath) then
			xml = FileUtil.readFile(manifestPath)
			if xml then
				doc = nil
				begin
					doc = REXML::Document.new( xml )
				rescue REXML::ParseException=>error
					error.to_s.strip!
				end

				if doc then
					# packagename
					doc.elements.each("manifest[@package]") do |anElement|
						result[:packageName] = anElement.attributes["package"]
					end

					# sharedUserId
					doc.elements.each("manifest[@sharedUserId]") do |anElement|
						result[:sharedUserId] = anElement.attributes["sharedUserId"]
					end

					# targetSdkVersion
					doc.elements.each("manifest/uses-sdk[@targetSdkVersion]") do |anElement|
						result[:targetSdkVersion] = anElement.attributes["targetSdkVersion"]
					end

					# persist
					doc.elements.each("//application[@persistent]") do |anElement|
						result[:persistent] = anElement.attributes["persistent"]
					end

					# uses-permissions
					doc.elements.each("//uses-permission[@name]") do |anElement|
						result[:usesPermissions] << anElement.attributes["name"]
					end
					result[:usesPermissions].uniq!
					result[:usesPermissions].sort!

					# uses-libraries
					doc.elements.each("//uses-library[@name]") do |anElement|
						result[:usesLibraries] << anElement.attributes["name"]
					end
					result[:usesLibraries].uniq!
					result[:usesLibraries].sort!

					# uses-features
					doc.elements.each("//uses-feature[@name]") do |anElement|
						if !anElement.attributes.has_key?("required") || anElement.attributes["required"].to_s.strip.downcase == "true" then 
							result[:usesFeatures] << anElement.attributes["name"]
						end
					end
					result[:usesFeatures].uniq!
					result[:usesFeatures].sort!

					# static broadcast receivers
					doc.elements.each("//receiver/intent-filter/action[@name]") do |anElement|
						result[:broadcastIntents] << anElement.attributes["name"]
					end
					result[:broadcastIntents].uniq!
					result[:broadcastIntents].sort!
				end
			end
		end

		return result
	end

	DEF_TOMBSTONE="tombstone.txt"
	DEF_TOMBSTONE_FILESIZE="fileSize:"
	DEF_TOMBSTONE_APKNAME="apkName:"
	DEF_TOMBSTONE_SIGNATURE="signature:"
	DEF_TOMBSTONE_APKPATH="apkPath:"

	def self.parseTombstone(tombstonePath)
		result = {:apkName=>nil, :fileSize=>nil, :signature=>nil, :apkPath=>nil}

		tombstonePath = "#{FileUtil.getDirectoryFromPath(tombstonePath)}/#{DEF_TOMBSTONE}"

		if File.exist?(tombstonePath) then
			buf = FileUtil.readFileAsArray(tombstonePath)
			buf.each do |aLine|
				result[:apkSize] = aLine[DEF_TOMBSTONE_FILESIZE.length..aLine.length].to_i if aLine.include?(DEF_TOMBSTONE_FILESIZE)
				result[:apkName] = aLine[DEF_TOMBSTONE_APKNAME.length..aLine.length] if aLine.include?(DEF_TOMBSTONE_APKNAME)
				result[:signature] = aLine[DEF_TOMBSTONE_SIGNATURE.length..aLine.length] if aLine.include?(DEF_TOMBSTONE_SIGNATURE)
				result[:apkPath] = aLine[DEF_TOMBSTONE_APKPATH.length..aLine.length] if aLine.include?(DEF_TOMBSTONE_APKPATH)
			end
		end

		return result
	end

	DEF_ANDROID_EXECLUDE=[
		"java.",
		"javax.",
		"android.",
		"com.android.",
		"com.google.android.gms."
	]

	DEF_JAVA_IMPORT="import "
	DEF_JAVA_IMPORT_LEN=DEF_JAVA_IMPORT.length

	def self._parseJavaSrcLine(aLine, result, excludes, importsMatch)
		shouldContinue = true

		if aLine.start_with?(DEF_JAVA_IMPORT) then
			aLine = aLine[DEF_JAVA_IMPORT_LEN...aLine.length].strip
			aLine=aLine[0..aLine.length-2] if aLine.end_with?(";")
			result[:imports] << aLine if !excludes.any? {|e| aLine.start_with?(e)} && (importsMatch==nil || aLine.match(importsMatch)!=nil)
		elsif aLine.include?("class ") || aLine.include?("interface ") then
			shouldContinue = false
		end

		return shouldContinue
	end

	def self._parseJavaSrc(javaSrc, result, excludes, importsMatch)
		if javaSrc && FileTest.exist?(javaSrc) then
			fileReader = File.open(javaSrc)
			if fileReader then
				while !fileReader.eof
					break if !_parseJavaSrcLine( StrUtil.ensureUtf8(fileReader.readline).strip, result, excludes, importsMatch)
				end
				fileReader.close
			end
		end

		return result
	end

	def self._importCleanup(imports)
		result = []

		imports.uniq!

		wildcard = []
		imports.each do |anImport|
			wildcard << anImport[0..anImport.length-3] if anImport.end_with?("*")
		end

		wildcard.uniq!
		result = wildcard

		imports.each do |anImport|
			result << anImport if !wildcard.any? {|e| anImport.start_with?(e)}
		end

		result.uniq!
		result.sort!

		return result
	end

	def self.parseJavaSource(javaSrcPath, excludes=DEF_ANDROID_EXECLUDE, importsMatch)
		result = {:imports=>[]}

		javaSrcPath = FileUtil.getDirectoryFromPath(javaSrcPath)
		javaSrcs = FileUtil.getRegExpFilteredFiles(javaSrcPath, "\.java$")

		javaSrcs.each do | aJavaSrcPath|
			_parseJavaSrc(aJavaSrcPath, result, excludes, importsMatch)
		end

		result[:imports] = _importCleanup(result[:imports])

		return result
	end
end


class AppAnalyzerExecutor < TaskAsync
	DEF_ANDROID_MANIFEST = "AndroidManifest.xml"

	def initialize(appPath, options, resultCallback)
		super("AppAnalyzerExecutor #{appPath}")
		@appPath = appPath
		@verbose = options[:verbose]
		@options = options
		@resultCallback = resultCallback
	end

	def _matchFilter?(value, filter)
		result = false

		if filter && value.to_s then
			isRegExpFilter = true
			if filter.to_s.include?(">") || filter.to_s.include?("<") then
				filter={
					:operateGreater=>filter.to_s.include?(">"),
					:value=>filter.to_i
				}
				isRegExpFilter = false
			else
				filter = Regexp.new(filter.to_s) if !filter.kind_of?(Regexp)
			end
			if value.kind_of?(Array) then
				value.each do |aVal|
					if isRegExpFilter then
						result = result | (aVal.to_s.match( filter )!=nil)
					else
						result = result | (filter[:operateGreater] ? (aVal.to_i>filter[:value]) : (aVal.to_i<filter[:value]))
					end
				end
			else
				if isRegExpFilter then
					result = (value.to_s.match( filter ) !=nil)
				else
					result = filter[:operateGreater] ? (aVal.to_i>filter[:value]) : (aVal.to_i<filter[:value])
				end
			end
		else
			result = true
		end

		return result
	end

	def execute
		result = AndroidAnalyzeUtil.parseAndroidManifest(@appPath)
		tombstone = AndroidAnalyzeUtil.parseTombstone(@appPath)
		result[:apkSize] = tombstone[:apkSize] if tombstone[:apkName]
		result[:apkPath] = tombstone[:apkPath] if tombstone[:apkPath]
		result[:signature] = tombstone[:signature] if tombstone[:signature]
		codeAnalysis = AndroidAnalyzeUtil.parseJavaSource(@appPath, @options[:importExcludes], @options[:importsMatch])
		result[:imports] = codeAnalysis[:imports] if !codeAnalysis[:imports].empty?

		if ( result && result[:packageName] && @resultCallback!=nil ) then
			@resultCallback.call(result) if _matchFilter?(result[:packageName],		@options[:filterPackageName]) &&
											_matchFilter?(result[:sharedUserId],	@options[:filterSharedUid]) &&
											_matchFilter?(result[:targetSdkVersion],@options[:filterTargetSdk]) &&
											_matchFilter?(result[:persistent],		@options[:filterPersistent]) &&
											_matchFilter?(result[:usesPermissions],	@options[:filterPermissions]) &&
											_matchFilter?(result[:usesLibraries],	@options[:filterLibraries]) &&
											_matchFilter?(result[:usesFeatures],	@options[:filterFeatures]) &&
											_matchFilter?(result[:broadcastIntents],@options[:filterBroadcastIntents]) &&
											(!result.has_key?("apkSize") || _matchFilter?(result[:apkSize], @options[:filterApkSize])) &&
											(!result.has_key?("apkPath") || _matchFilter?(result[:apkPath], @options[:filterApkPath])) &&
											(!result.has_key?("signature") || _matchFilter?(result[:signature], @options[:filterSignature]))
		end

		_doneTask()
	end
end

$g_criticalSection = Mutex.new
$g_result =[]
def addResult(result)
	$g_criticalSection.synchronize {
		$g_result << result
	}
end


#---- main --------------------------
options = {
	:verbose => false,
	:reportOutPath => nil,
	:outputSections => "packageName|apkPath|sharedUserId|signature|targetSdkVersion|persistent|usesPermissions|usesLibraries|usesFeatures|broadcastIntents|apkSize|imports",
	:importExcludes => AndroidAnalyzeUtil::DEF_ANDROID_EXECLUDE,
	:importsMatch => nil,
	:filterPackageName => nil,
	:filterSharedUid => nil,
	:filterTargetSdk => nil,
	:filterPersistent => nil,
	:filterPermissions => nil,
	:filterLibraries => nil,
	:filterFeatures => nil,
	:filterBroadcastIntents => nil,
	:filterApkSize => ">0",
	:filterSignature => nil,
	:filterApkPath => nil,
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

reporter = MarkdownReporter

OptionParser.new do |opts|
	opts.banner = "Usage: an Android App Source Dir or scan root [options]"

	opts.on("-j", "--numOfThreads=", "Specify number of threads (default:#{options[:numOfThreads]})") do |numOfThreads|
		options[:numOfThreads] = numOfThreads.to_i
		options[:numOfThreads] = 1 if !options[:numOfThreads]
	end

	opts.on("-v", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end

	opts.on("-o", "--reportOutPath=", "Specify output path (stdout if not specified") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
	end

	opts.on("-r", "--reportFormat=", "Specify report format markdown or csv (default:markdown)") do |reportFormat|
		case reportFormat.to_s.downcase
		when "csv"
			reporter = CsvReporter
		end
	end

	opts.on("-e", "--importExcludes=", "Specify output sections (default:#{options[:importExcludes].join(",")})") do |importExcludes|
		options[:importExcludes] = importExcludes.to_s.split(",")
	end

	opts.on("-i", "--importsMatch=", "Specify output sections (default:#{options[:importsMatch]})") do |importsMatch|
		options[:importsMatch] = importsMatch
	end

	opts.on("-n", "--filterPackageName=", "Filter for PackageName") do |filterPackageName|
		options[:filterPackageName] = filterPackageName
	end

	opts.on("-u", "--filterSharedUid=", "Filter for SharedUserId") do |filterSharedUid|
		options[:filterSharedUid] = filterSharedUid
	end

	opts.on("-t", "--filterTargetSdk=", "Filter for TargetSdkVersion") do |filterTargetSdk|
		options[:filterTargetSdk] = filterTargetSdk
	end

	opts.on("-p", "--filterPersistent=", "Filter for persistent") do |filterPersistent|
		options[:filterPersistent] = filterPersistent
	end

	opts.on("-m", "--filterPermissions=", "Filter for uses-permission") do |filterPermissions|
		options[:filterPermissions] = filterPermissions
	end

	opts.on("-l", "--filterLibraries=", "Filter for uses-library") do |filterLibraries|
		options[:filterLibraries] = filterLibraries
	end

	opts.on("-f", "--filterFeatures=", "Filter for uses-feature") do |filterFeatures|
		options[:filterFeatures] = filterFeatures
	end

	opts.on("-b", "--filterBroadcastIntents=", "Filter for Broadcast Intents") do |filterBroadcastIntents|
		options[:filterBroadcastIntents] = filterBroadcastIntents
	end

	opts.on("", "--filterSignature=", "Filter for signature finger print") do |filterSignature|
		options[:filterSignature] = filterSignature
	end

	opts.on("", "--filterApkPath=", "Filter for apkPath") do |filterApkPath|
		options[:filterApkPath] = filterApkPath
	end

	opts.on("-s", "--outputSections=", "Specify output sections (default:#{options[:outputSections]})") do |outputSections|
		options[:outputSections] = outputSections.to_s
	end
end.parse!

if (ARGV.length < 1) then
	exit(-1)
end

if options[:importsMatch] then
	options[:importsMatch] = Regexp.new( options[:importsMatch] )
end

appPaths = []
if FileTest.directory?(ARGV[0]) then
	appPaths = FileUtil.getRegExpFilteredFiles(ARGV[0], AppAnalyzerExecutor::DEF_ANDROID_MANIFEST)
elsif File.exist?(ARGV[0]) then
	appPaths << ARGV[0]
else
	puts "Please specify an app path or root dirctory of application source codes"
end

taskMan = TaskManagerAsync.new( options[:numOfThreads].to_i )
appPaths.each do |aTarget|
	taskMan.addTask( AppAnalyzerExecutor.new(
		aTarget, 
		options,
		method(:addResult)
		)
	)
end
taskMan.executeAll()
taskMan.finalize()

$g_result.sort! do |a, b|
	ret = a[:packageName].casecmp(b[:packageName])
	ret == 0 ? a[:packageName] <=> b[:packageName] : ret
end

reporter = reporter.new( options[:reportOutPath] )

reporter.titleOut("AndroidManifest.xml parse result")
reporter.report($g_result, options[:outputSections])
