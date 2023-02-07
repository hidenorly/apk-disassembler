#!/usr/bin/env ruby

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

require_relative 'FileUtil'

class Reporter
	def ensureCorrespondingExt(path)
		return path
	end
	def setupOutStream(reportOutPath, enableAppend = false)
		outStream = nil
		if reportOutPath then
			if reportOutPath.kind_of?( Stream ) then
				outStream = reportOutPath
			else
				outStream = FileUtil.getFileWriter( ensureCorrespondingExt(reportOutPath), enableAppend)
			end
		end
		outStream = outStream ? outStream : STDOUT
		@outStream = outStream
	end

	def initialize(reportOutPath, enableAppend = false)
		setupOutStream(reportOutPath, enableAppend)
	end

	def close()
		if @outStream then
			@outStream.close() if @outStream!=STDOUT
			@outStream = nil
		end
	end

	def titleOut(title)
		@outStream.puts title if @outStream
	end

	def subTitleOut(title, level = 2)
		@outStream.puts title if @outStream
	end

	def println(msg = "")
		@outStream.puts msg if @outStream
	end

	def _getMaxLengthData(data)
		result = !data.empty? ? data[0] : {}

		data.each do |aData|
			result = aData if aData.kind_of?(Enumerable) && aData.to_a.length > result.to_a.length
		end

		return result
	end

	def _ensureFilteredHash(data, outputSections)
		result = data

		if outputSections then
			result = {}

			outputSections.each do |aKey|
				found = false
				data.each do |theKey, theVal|
					if theKey.to_s.strip.start_with?(aKey) then
						result[aKey] = theVal
						found = true
						break
					end
				end
				result[aKey] = nil if !found
			end
		end

		return result
	end

	def report(data, outputSections=nil, options={})
		outputSections = outputSections ? outputSections.split("|") : nil

		if data.length then
			keys = _getMaxLengthData(data) #data[0]
			if keys.kind_of?(Hash) then
				keys = _ensureFilteredHash(keys, outputSections)
				_conv(keys, true, false, true, options)
			elsif outputSections then
				_conv(outputSections, true, false, true, options)
			end

			data.each do |aData|
				aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
				_conv(aData)
			end
		end
	end

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
		@outStream.puts aData if @outStream
	end
end

class MarkdownReporter < Reporter
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
	end
	def titleOut(title)
		if @outStream
			@outStream.puts "\# #{title}"
			@outStream.puts ""
		end
	end

	def subTitleOut(title, level = 2)
		if @outStream
			@outStream.puts "#{"\#"*level} #{title}"
			@outStream.puts ""
		end
	end

	def ensureCorrespondingExt(path)
		return path.end_with?(".md") ? path : "#{path}.md"
	end

	def reportFilter(aLine)
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? " <br> " : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
		separator = "|"
		aLine = separator
		count = 0
		if aData.kind_of?(Enumerable) then
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					aLine = "#{aLine} #{aKey} #{separator}" if keyOutput
					aLine = "#{aLine} #{reportFilter(theVal)} #{separator}" if valOutput
					count = count + 1
				end
			elsif aData.kind_of?(Array) then
				aData.each do |theVal|
					aLine = "#{aLine} #{reportFilter(theVal)} #{separator}" if valOutput
					count = count + 1
				end
			end
			@outStream.puts aLine if @outStream
			if firstLine && count then
				aLine = "|"
				for i in 1..count do
					aLine = "#{aLine} :--- |"
				end
				@outStream.puts aLine if @outStream
			end
		else
			@outStream.puts "#{separator} #{reportFilter(aData)} #{separator}" if @outStream
		end
	end
end

class CsvReporter < Reporter
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
	end

	def titleOut(title)
		@outStream.puts "" if @outStream
	end

	def subTitleOut(title, level = 2)
		titleOut(title)
	end

	def ensureCorrespondingExt(path)
		return path.end_with?(".csv") || path.end_with?(".txt") ? path : "#{path}.csv"
	end

	def reportFilter(aLine)
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? "|" : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
		aLine = ""
		if aData.kind_of?(Enumerable) then
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{aKey}" if keyOutput
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{reportFilter(theVal)}" if valOutput
				end
			elsif aData.kind_of?(Array) then
				aData.each do |theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{reportFilter(theVal)}" if valOutput
				end
			end
			@outStream.puts aLine if @outStream
		else
			@outStream.puts "#{reportFilter(aData)}" if @outStream
		end
	end
end

class XmlReporter < Reporter
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
	end

	def titleOut(title)
		if @outStream then
			@outStream.puts "<!-- #{title} --/>"
			@outStream.puts ""
		end
	end

	def subTitleOut(title, level = 2)
		titleOut(title)
	end

	def ensureCorrespondingExt(path)
		return path.end_with?(".xml") ? path : "#{path}.xml"
	end

	def reportFilter(aLine)
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? "\n" : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def report(data, outputSections=nil, options={})
		outputSections = outputSections ? outputSections.split("|") : nil
		mainKey = nil
		if outputSections then
			mainKey = outputSections[0]
		end

		data.each do |aData|
			aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
			if mainKey then
				mainVal = aData.has_key?(mainKey) ? aData[mainKey] : ""
				aData.delete(mainKey)
				@outStream.puts "<#{mainKey} #{mainVal ? "value=\"#{mainVal}\"" : ""}>" if @outStream
				_subReport(aData, 4)
				@outStream.puts "</#{mainKey}>" if @outStream
			else
				_subReport(aData, 0)
			end
		end
	end

	def _isEnumerable(theData)
		result = false
		theData.each do |aData|
			if aData.kind_of?(Enumerable) then
				result = true
				break
			end
		end
		return result
	end

	def _subReport(aData, baseIndent=4, keyOutput=true, valOutput=true, firstLine=false)
		separator = "\n"
		if aData.kind_of?(Enumerable) then
			indent = baseIndent + 4
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					@outStream.puts "#{" "*baseIndent}<#{aKey}>" if @outStream
					if theVal.kind_of?(Enumerable) then
						_subReport(theVal, indent)
					else
						aVal = reportFilter(theVal).to_s
						if aVal && !aVal.empty? then
							@outStream.puts "#{" "*indent}#{aVal}" if @outStream
						end
					end
					@outStream.puts "#{" "*baseIndent}</#{aKey}>" if @outStream
				end
			elsif aData.kind_of?(Array) then
				isEnumerable = _isEnumerable(aData)
				@outStream.puts "#{" "*baseIndent}<data>" if isEnumerable && @outStream
				aLine = ""
				aData.each do |theVal|
					if theVal.kind_of?(Enumerable) then
						_subReport(theVal, indent)
					else
						aVal = reportFilter(theVal)
						if aVal && !aVal.empty? then
							aLine = "#{aLine}#{" "*indent}#{aVal}#{separator}" if valOutput
						end
					end
				end
				if @outStream then
					@outStream.puts aLine
					@outStream.puts "#{" "*baseIndent}</data>" if isEnumerable
				end
			else
				aVal = reportFilter(aData)
				if aVal && !aVal.empty? then
					@outStream.puts "#{" "*indent}#{aVal}" if @outStream
				end
			end
		else
			aVal = reportFilter(aData)
			if aVal && !aVal.empty? then
				@outStream.puts "#{" "*indent}#{aVal}" if @outStream
			end
		end
	end
end
