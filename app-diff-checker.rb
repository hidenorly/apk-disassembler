#!/usr/bin/ruby

# Copyright 2022, 2025 hidenorly
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

require 'fileutils'
require 'optparse'
require 'shellwords'
require_relative "TaskManager"
require_relative "FileUtil"
require_relative "StrUtil"
require_relative "ExecUtil"
require_relative "Reporter"
require_relative "MarkdownTableDiff"


class ProjectUtil
	def self._checkBuildSuccessful(path)
		result = true

		basePath = ExecUtil.getExecResultEachLine("ls #{path}")
		if !basePath.empty? then
			basePath = basePath[0]
		end

		exec_cmd = "du #{path}/#{basePath.to_s}/system.img" #"tree -d #{Shellwords.escape(path)} | wc -l"
		result = ExecUtil.getExecResultEachLine(exec_cmd, path)
		result = !result.empty? ? result[0].to_s : "0"
		result = result.to_i

		return result > 300000 #3000 # tenative method. TO DO: Need to fix.
	end
	def self._omitInvalidImage(images)
		result = []
		images.each do |anImage|
			result << anImage if _checkBuildSuccessful(anImage)
		end
		return result
	end
	def self.getProjectImages(imageDirectory, imageDirRegexp)
		# enumerate images
		images = []
		FileUtil.iteratePath(imageDirectory, imageDirRegexp, images, false, true)
		images.sort!

		return _omitInvalidImage(images)
	end

	def self.getPrevAndCurrentFromImages(images)
		current = nil
		previous = nil
		if images.length>=2 then
			_images = images.dup()
			current = _images.pop()
			previous = _images.pop()
		end
		return current, previous
	end

	def self._getAPKPaths(imageDirectory)
		pathes = []
		result = ExecUtil.getExecResultEachLine("ls #{imageDirectory}")
		if !result.empty? then
			pathBase = "#{imageDirectory}/#{result[0]}"
			pathes << "#{pathBase}/system"
			pathes << "#{pathBase}/system_ext"
			pathes << "#{pathBase}/product"
			pathes << "#{pathBase}/vendor"
			pathes << "#{pathBase}/odm"
			pathes << "#{pathBase}/oem"
		end
=begin
		scanKey = Regexp.new("^#{Regexp.escape(imageDirectory)}\/[0-9a-zA-Z_-]+\/(system|vendor)")
		FileUtil.iteratePath(imageDirectory, scanKey, pathes, true, true, true)
=end
		return pathes
	end

	def self.removeOldConvertedApks(apkOutDirectory, aProjectDir, numOfKeepImage, verbose=false)
		projectName = FileUtil.getFilenameFromPath(aProjectDir)
		images = []
		FileUtil.iteratePath(apkOutDirectory, Regexp.escape("#{projectName}-"), images, false, true)
		images.each do |anImage|
			FileUtil.removeDirectoryIfNoFile(anImage)
		end
		images = []
		FileUtil.iteratePath(apkOutDirectory, Regexp.escape("#{projectName}-"), images, false, true)
		images.sort!

		# remove unnecessary images
		if images.length > numOfKeepImage then
			remove_images = images.take( images.length-numOfKeepImage )
			remove_images.each do |aRemoveImagePath|
				puts "Removing...#{aRemoveImagePath}" if verbose
				FileUtils.rm_rf( aRemoveImagePath )
			end
			images = images.drop( images.length-numOfKeepImage )
		end
		return images
	end

	DEF_EXEC_TIMEOUT_FOR_JAD = 30

	def self._convertApkToSrc(imageDirectory, outputDirectory, enableSrcAnalysis)
		projectDate = FileUtil.getFilenameFromPath(imageDirectory)
		projectName = FileUtil.getFilenameFromPath(FileUtil.getDirectoryFromPath(imageDirectory))
		convertedApkPath = "#{outputDirectory}/#{projectName}-#{projectDate}"

		FileUtil.ensureDirectory(convertedApkPath)# if !FileTest.directory?(convertedApkPath)

		apkPaths = _getAPKPaths(imageDirectory)

		apkPaths.each do |anApkPath|
			exec_cmd = "apk-disassembler.rb #{Shellwords.escape(anApkPath)} -o #{Shellwords.escape(convertedApkPath)} -m -t -f -p" # -m:AndroidManifest, -t:tombstone, -f:tombstone:apkSignature -p:tombstone:apkPath
			exec_cmd = "#{exec_cmd} -s -e #{DEF_EXEC_TIMEOUT_FOR_JAD}" if enableSrcAnalysis # -s:sourcecode, -e:exec timeout for jad
			ExecUtil.execCmd(exec_cmd)
		end

		return convertedApkPath
	end

	def self._analyzeAppSrc(appSrcPaths, reportDirectory, importFilters, outputSection)
		result = []

		appSrcPaths.each do |aSrcPath|
			reportPath = "#{reportDirectory}/#{FileUtil.getFilenameFromPath(aSrcPath)}.md"
			result << reportPath

			exec_cmd = "app-analyzer.rb #{Shellwords.escape(aSrcPath)}"
			exec_cmd = "#{exec_cmd} -s \"#{outputSection}\"" if outputSection
			exec_cmd = "#{exec_cmd} -i \"#{importFilters}\"" if importFilters
			exec_cmd = "#{exec_cmd} > #{Shellwords.escape(reportPath)}"
			exec_cmd = "#{exec_cmd} 2> /dev/null"

			ExecUtil.execCmd(exec_cmd, reportDirectory, false)
		end

		return result
	end

	KEY_COLUMN="packageName"

	def self._makeReportFromDiff(reporter, parser, reportPath, reportPaths, reportBase, reportSections)
		# get cols
		cols=[]
		reportPaths.each do |aReportPath|
			aCols= parser.getTableColsFromFile(aReportPath)
			if aCols then
				cols = aCols
				break
			end
		end

		# read diff report
		body = FileUtil.readFileAsArray(reportPath)
		added, removed = DiffTableUtil.getDiffTable(body)
		body =[]

		# convert the diffed report with cols
		added = DiffTableUtil.convertArrayToHashWithCols(added, cols, KEY_COLUMN)
		removed = DiffTableUtil.convertArrayToHashWithCols(removed, cols, KEY_COLUMN)

		#
		diffIgnoreCols = [ KEY_COLUMN ]
		pureAdded, pureRemoved, diffed = DiffTableUtil.getAnalyzedDiffedData(added, removed, cols, diffIgnoreCols)

		if !pureAdded.empty? && (!reportSections || reportSections.include?("added")) then
			reporter.titleOut(body, "pure added package(s)")
			reporter.report(body, pureAdded)
			reporter.println(body)
		end

		if !pureRemoved.empty? && (!reportSections || reportSections.include?("removed")) then
			reporter.titleOut(body, "pure removed package(s)")
			reporter.report(body, pureRemoved)
			reporter.println(body)
		end

		if !diffed.empty? && (!reportSections || reportSections.include?("diffed")) then
			reporter.titleOut(body, "diffed package(s)")
			reporter.report(body, diffed)
			reporter.println(body)
		end

		# create header
		insertBody = []
		reportPaths.each do |aReportPath|
			aReportPath = FileUtil.getFilenameFromPath(aReportPath)
			insertBody << "* [#{aReportPath}](#{reportBase}/#{aReportPath})"
		end
		insertBody << ""

		body = insertBody.concat(body)
		FileUtil.writeFile(reportPath, body)
	end

	def self._createReportDiff(reportPaths, outputDiffReportPath)
		exec_cmd = "diff -u -r -N #{Shellwords.escape(reportPaths[0])} #{Shellwords.escape(reportPaths[1])}"
		exec_cmd = "#{exec_cmd} | grep -P '^(\\+|\\-)\\|' > #{Shellwords.escape(outputDiffReportPath)}"
		ExecUtil.execCmd(exec_cmd, FileUtil.getDirectoryFromPath(outputDiffReportPath), false)
	end

	def self.createAPKAnalyzeReport(apkOutDirectory, previousImage, latestImage, reportDirectory, reportBase, reportTitle=nil, dontReportIfNoIssue=false, enableSrcAnalysis=false, importFilters=nil, outputSection=nil, reportSections=nil)
		reportName = "#{reportTitle ? reportTitle+"-" : ""}#{FileUtil.getFilenameFromPath(previousImage)}_#{FileUtil.getFilenameFromPath(latestImage)}.md"
		reportPath = "#{reportDirectory}/#{reportName}"

		# step-1 : convert apk to source code (convert binary xml to plain text)
		srcPaths = []
		srcPaths << _convertApkToSrc(previousImage, apkOutDirectory, enableSrcAnalysis)
		srcPaths << _convertApkToSrc(latestImage, apkOutDirectory, enableSrcAnalysis)

		# step-2 : analyze the code
		reportPaths=_analyzeAppSrc(srcPaths, reportDirectory, importFilters, outputSection)

		# step-4 : diff the analyzed report
		_createReportDiff(reportPaths, reportPath)

		if dontReportIfNoIssue && !File.size?(reportPath) then
			reportName = nil
			FileUtils.rm_f(reportPath)
		end

		# step-6 : Add link to the detailed report
		_makeReportFromDiff(MarkdownReporter, MarkdownParser, reportPath, reportPaths, reportBase, reportSections) if reportPath && File.size?(reportPath)

		if dontReportIfNoIssue && !File.size?(reportPath) then
			reportName = nil
			FileUtils.rm_f(reportPath)
		end

		return reportName
	end

	def self.getPathOfLatestAndPreviousReports(reportDirectory, reportTitle, currentReportName)
		result= []
		paths = []
		FileUtil.iteratePath(reportDirectory, Regexp.new("^#{Regexp.escape(reportTitle)}.*\.md$"), paths, false, false)
		paths.sort!
		index = paths.rindex{|anItem| anItem.include?(reportTitle)}
		if index && index>0 then
			result << paths[index-1]
			result << paths[index]
		end
		return result
	end

	def self._getLabel(path)
		path = FileUtil.getFilenameFromPath(path)
		pos = path.rindex(".md")
		path = path.slice(0, pos) if pos
		pos = path.rindex("-")
		path = path.slice(pos+1, path.length) if pos

		return path
	end

	def self.createDiffReport(reportTitle, reportName, reportBase, reportPaths)
		if reportPaths.length == 2 then
			reportName = "Diff-#{reportTitle}-#{_getLabel(reportPaths[0])}_#{_getLabel(reportPaths[1])}.md"
			reportPath = "#{FileUtil.getDirectoryFromPath(reportPaths[0])}/#{reportName}"

			# get cols
			cols=[]
			reportPaths.each do |aReportPath|
				aCols= MarkdownParser.getTableColsFromFile(aReportPath)
				if aCols then
					cols = aCols
					break
				end
			end

			# read data
			oldTables_ = MarkdownParser.getMarkdownTableFromFile(reportPaths[0], true, true)
			newTables_ = MarkdownParser.getMarkdownTableFromFile(reportPaths[1], true, true)

			oldTables = {}
			newTables = {}
			sections = []
			oldTables_.each do |aSection, aTable|
				oldTables[aSection] = DiffTableUtil.convertArrayToHashWithCols(aTable, cols, KEY_COLUMN)
				sections << aSection
			end
			newTables_.each do |aSection, aTable|
				newTables[aSection] = DiffTableUtil.convertArrayToHashWithCols(aTable, cols, KEY_COLUMN)
				sections << aSection
			end
			sections.uniq!

			diffIgnoreCols = [ KEY_COLUMN ]
			diffeds = {}

			sections.each do |aSection|
				aResult = nil
				if newTables.has_key?(aSection) && oldTables.has_key?(aSection) then
					pureAdded, pureRemoved, diffed = DiffTableUtil.getAnalyzedDiffedData(newTables[aSection], oldTables[aSection], cols, diffIgnoreCols, true)
					pureAdded = pureAdded + diffed + pureRemoved
					aResult = pureAdded if !pureAdded.empty?

				elsif newTables.has_key?(aSection) && !oldTables.has_key?(aSection) then
					aResult = DiffTableUtil.addPrefixEachDatas(newTables[aSection], [], "+")
				else
					aResult = DiffTableUtil.addPrefixEachDatas(oldTables[aSection], [], "-")
				end
				diffeds[aSection] = aResult if aResult && !aResult.empty?
			end

			body = []
			reporter = MarkdownReporter
			diffeds.each do |aSection, diffed|
				reporter.titleOut(body, aSection)
				reporter.report(body, diffed)
				reporter.println(body)
			end

			if !body.empty? then
				# create header
				insertBody = []
				reportPaths.each do |aReportPath|
					aReportPath = FileUtil.getFilenameFromPath(aReportPath)
					insertBody << "* [#{aReportPath}](#{reportBase}/#{aReportPath})"
				end
				insertBody << ""

				body = insertBody.concat(body)
				FileUtil.writeFile(reportPath, body)

				reportName = FileUtil.getFilenameFromPath(reportPath)
			else
				reportName = nil
			end
		end

		return reportName
	end
end


options = {
	:reportDirectory => ".",
	:reportBase => nil,
	:imageDirectory => ["."],
	:imageDirRegexp => "[0-9]+",
	:apkOutDirectory => ".",
	:numOfKeepApkOut => 7,
	:outputReportSectionEach => "added|removed|diffed",
	:outputReportSectionCross => "added|removed|diffed",
	:outputSectionsEach => nil,
	:outputSectionsCross => nil,
	:dontReportIfNoIssue => false,
	:enableDiffOnCross => false,
	:enableSrcAnalysis => false,
	:importFilters => nil,
	:verbose => false
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: "

	opts.on("-i", "--imageDirectory=", "Specify imageDirectory directories (projectA,projectB) (default:#{options[:imageDirectory]})") do |imageDirectory|
		options[:imageDirectory] = imageDirectory.to_s.split(",")

	end

	opts.on(nil, "--imageDirRegexp=", "Specify image path regexp (default:#{options[:imageDirRegexp]})") do |imageDirRegexp|
		options[:imageDirRegexp] = imageDirRegexp
	end

	opts.on("-a", "--apkOutDirectory=", "Specify apkOutDirectory directories (default:#{options[:apkOutDirectory]})") do |apkOutDirectory|
		options[:apkOutDirectory] = apkOutDirectory

	end

	opts.on("-k", "--numOfKeepApkOut=", "Specify number of keep converted apk (default:#{options[:numOfKeepApkOut]})") do |numOfKeepApkOut|
		options[:numOfKeepApkOut] = numOfKeepApkOut.to_i
		options[:numOfKeepApkOut] = (options[:numOfKeepApkOut] < 2) ? 2 : options[:numOfKeepApkOut]
	end

	opts.on("-r", "--reportDirectory=", "Specify report directory (default:#{options[:reportDirectory]})") do |reportDirectory|
		options[:reportDirectory] = reportDirectory
	end

	opts.on("-u", "--reportBase=", "Specify compat_reports base URL (default:#{options[:reportBase]})") do |reportBase|
		options[:reportBase] = reportBase
	end

	opts.on("-s", "--enableSrcAnalysis", "Enable source code analysis") do
		options[:enableSrcAnalysis] = true
	end

	opts.on("-f", "--importFilters=", "Specify importFilters for source code analysis (regexp)") do |importFilters|
		options[:importFilters] = importFilters
		options[:enableSrcAnalysis] = true
	end

	opts.on("-d", "--dontReportIfNoIssue", "Specify to stop reporting if no issue found") do
		options[:dontReportIfNoIssue] = true
	end

	opts.on("-o", "--outputReportSectionEach=", "Specify to markdown report output section for each project (#{options[:outputReportSectionEach]})") do |outputReportSectionEach|
		options[:outputReportSectionEach] = outputReportSectionEach
	end

	opts.on("-x", "--outputReportSectionCross=", "Specify to markdown report output section for each project (#{options[:outputReportSectionCross]})") do |outputReportSectionCross|
		options[:outputReportSectionCross] = outputReportSectionCross
	end

	opts.on("-e", "--outputSectionsEach=", "Specify to output section for each project (See app-analyzer.rb's outputsection)") do |outputSectionsEach|
		options[:outputSectionsEach] = outputSectionsEach
	end

	opts.on("-c", "--outputSectionsCross=", "Specify to output section for cross projects (See app-analyzer.rb's outputsection)") do |outputSectionsCross|
		options[:outputSectionsCross] = outputSectionsCross
	end

	opts.on(nil, "--enableDiffOnCross", "Specify if you need to have diff report on cross projects report") do
		options[:enableDiffOnCross] = true
	end

	opts.on("-v", "--verbose", "Enable verbose status output (default:#{options[:verbose]})") do
		options[:verbose] = true
	end
end.parse!

options[:reportDirectory] = File.expand_path(options[:reportDirectory])
FileUtil.ensureDirectory(options[:reportDirectory])
options[:apkOutDirectory] = File.expand_path(options[:apkOutDirectory])
FileUtil.ensureDirectory(options[:apkOutDirectory])

options[:outputReportSectionEach] = options[:outputReportSectionEach].split("|")
options[:outputReportSectionCross] = options[:outputReportSectionCross].split("|")

projects = []
options[:imageDirectory].each do |aProjectDir|
	aProjectDir = File.expand_path(aProjectDir)
	puts "aProjectDir=#{aProjectDir}" if options[:verbose]
	images = ProjectUtil.getProjectImages(aProjectDir, options[:imageDirRegexp])
	projects << {:project=>aProjectDir, :image=>images.dup().pop()}

	# API compatibility check between latest & the previous on same project
	latestImage, previousImage = ProjectUtil.getPrevAndCurrentFromImages(images)
	puts "latest=#{latestImage}, previous=#{previousImage}" if options[:verbose]
	if latestImage && previousImage then
		reportName = ProjectUtil.createAPKAnalyzeReport(
			options[:apkOutDirectory], previousImage, latestImage,
			options[:reportDirectory], options[:reportBase],
			"#{FileUtil.getFilenameFromPath(aProjectDir)}",
			options[:dontReportIfNoIssue],
			options[:enableSrcAnalysis],
			options[:importFilters],
			options[:outputSectionsEach],
			options[:outputReportSectionEach]
		)
		puts reportName if options[:dontReportIfNoIssue] && reportName && File.size("#{options[:reportDirectory]}/#{reportName}")
	end
end

projects.combination(2) do |a,b|
	puts "a=#{a}, b=#{b}" if options[:verbose]
	reportTitle = "#{FileUtil.getFilenameFromPath(a[:project])}-#{FileUtil.getFilenameFromPath(b[:project])}"
	reportName = ProjectUtil.createAPKAnalyzeReport(
		options[:apkOutDirectory], a[:image], b[:image],
		options[:reportDirectory], options[:reportBase],
		reportTitle,
		options[:dontReportIfNoIssue],
		options[:enableSrcAnalysis],
		options[:importFilters],
		options[:outputSectionsCross],
		options[:outputReportSectionCross]
	)
	if reportName && options[:enableDiffOnCross] then
		reportName = ProjectUtil.createDiffReport(
				reportTitle, reportName, options[:reportBase],
				ProjectUtil.getPathOfLatestAndPreviousReports(options[:reportDirectory], reportTitle, reportName)
			)
	end
	puts reportName if options[:dontReportIfNoIssue] && reportName && File.size("#{options[:reportDirectory]}/#{reportName}")
end

options[:imageDirectory].each do |aProjectDir|
	aProjectDir = File.expand_path(aProjectDir)
	ProjectUtil.removeOldConvertedApks(options[:apkOutDirectory], aProjectDir, options[:numOfKeepApkOut], options[:verbose])
end
