#  Copyright (C) 2021, 2022 hidenorly
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

# TaskManager and Task definitions

class Task
	attr_accessor :description

	def initialize(description)
		@description = description
	end
	def execute
	end
end

class TaskManager
	def initialize()
		@tasks = []
		@isRunning = false
	end

	def addTask(aTask)
		@tasks.push( aTask )
	end

	def executeAll
		@isRunning = true
		while !@tasks.empty? do
			aTask = @tasks.pop()
			aTask.execute()
		end
		@isRunning = false
	end

	def isRunning
		return @isRunning
	end

	def isRemainingTasks
		return @tasks.count > 0
	end

	def finalize
	end
end


# --- TaskAsync and TaskManagerAsync -------------

class TaskAsync < Task
	attr_accessor :description
	attr_accessor :taskCompleCallback
	attr_accessor :running

	def initialize(description)
		super( description )
		@running = false
		@taskCompleCallback = nil
	end
	def execute
		_doneTask()
	end

	def finalize
		@running = false
	end

	def _doneTask
		if nil != @taskCompleCallback then
			@taskCompleCallback.call(self) # completion callback
		end
	end
end

class TaskManagerAsync < TaskManager
	def initialize( numOfThread = TaskManagerAsync.getNumberOfProcessor() )
		@tasks = []
		@numOfThread = numOfThread
		@currentRunningTasks = 0
		@threads = []
		@criticalSection = Mutex.new
	end

	def addTask(aTaskAsync)
		aTaskAsync.taskCompleCallback = method(:_onTaskCompletion)
		@criticalSection.synchronize {
			super( aTaskAsync )
		}
	end

	def cancelTask( aTask )
		@tasks.delete( aTask )
		@criticalSection.synchronize {
			@currentRunningTasks = @currentRunningTasks - 1
		}
		aTask.running = false
		aTask.finalize()
	end

	def executeAll
		candidateTasks = []
		@criticalSection.synchronize {
			for aTask in @tasks do
				if( false == aTask.running ) then
					if ( @currentRunningTasks < @numOfThread ) then
						@currentRunningTasks = @currentRunningTasks + 1
						aTask.running = true
						candidateTasks.push( aTask )
					end
				end
			end
			for aTask in candidateTasks do
				@tasks.delete( aTask )
			end
		}

		for aTask in candidateTasks do
			@threads << Thread.new(aTask) do |task|
				task.execute()
			end
		end
	end

	def isRunning
		@criticalSection.synchronize {
			if @currentRunningTasks > 0 then return true end
		}
		return false
	end

	def isRemainingTasks
		@criticalSection.synchronize {
			if @tasks.count > 0 then return true end
		}
		return false
	end

	def _onTaskCompletion( task )
#		puts "done : #{task.description}"
		cancelTask( task )
		executeAll()
	end

	def finalize
		while isRemainingTasks() || isRunning()  do
			if ( isRunning() ) then
				sleep 0.1
#				puts "waiting ... done #{@currentRunningTasks}"
				@threads.each { |t| t.join }
			end
		end
	end

	def self.getNumberOfProcessor
		# try as Windows
		numOfProcessor = ENV['NUMBER_OF_PROCESSORS']
		if !numOfProcessor then
			# try as Linux
			exec_cmd = "cat /proc/cpuinfo 2> /dev/null | grep bogomips | wc -l"
			IO.popen(exec_cmd, "r") {|io|
				while !io.eof? do
					numOfProcessor= io.readline.strip.to_i
				end
				io.close()
			}
		end
		if !numOfProcessor || 0 == numOfProcessor then
			# try as MacOS
			exec_cmd = "sysctl -n hw.ncpu 2> /dev/null"
			IO.popen(exec_cmd, "r") {|io|
				while !io.eof? do
					numOfProcessor= io.readline.strip.to_i
				end
				io.close()
			}
		end
		numOfProcessor=4 if !numOfProcessor || 0 == numOfProcessor

		return numOfProcessor
	end
end


class TaskPool
	def initialize
		@criticalSection = Mutex.new
		@tasks = []
	end

	def enqueue(task)
		@criticalSection.synchronize {
			@tasks << task
		}
	end

	def dequeue
		result = nil
		@criticalSection.synchronize {
			result = @tasks.shift
		}
		return result
	end

	def erase(task)
		@criticalSection.synchronize {
			@tasks.delete(task)
		}
	end

	def clear
		@criticalSection.synchronize {
			@tasks = []
		}
	end

	def isEmpty
		return @tasks.empty?
	end
end

class TaskExecutor
	def initialize(taskPool)
		@taskPool = taskPool
		@thread = nil
		@criticalSection = Mutex.new
		@isRunnable = false
	end

	def execute
		@isRunnable = true
		if @thread == nil then
			@criticalSection.synchronize {
				@thread = Thread.new do
					while(@isRunnable) do
						@task = @taskPool.dequeue()
						if @task!=nil then
							@task.execute()
						else
							sleep 0.1
						end
					end
					@thread = nil
				end
			}
			@task = nil
		end
	end

	def terminate
		@isRunnable = false
		@criticalSection.synchronize {
			if @thread != nil then
				@thread.join
				@thread = nil
			end
		}
	end

	def cancelTaskIfRunning(task)
		if @task==task then
			isRunnable = @isRunnable
			terminate()
			execute() if isRunnable
		end
	end

	def isRunning
		return @thread != nil
	end
end

class ThreadPool
	def initialize(numOfThreads=TaskManagerAsync.getNumberOfProcessor())
		@taskPool = TaskPool.new()
		@threads = []
		for i in 0..numOfThreads do
			@threads << TaskExecutor.new(@taskPool)
		end
	end

	def addTask(task)
		@taskPool.enqueue(task)
	end

	def cancelTask(task)
		@taskPool.erase(task)
	end

	def executeAll
		@threads.each do |aTaskExecutor|
			aTaskExecutor.execute()
		end
	end

	def isRemainingTasks
		return !@taskPool.isEmpty()
	end

	def isRunning
		result = false
		@threads.each do |aTaskExecutor|
			result = result | aTaskExecutor.isRunning()
		end
		return result
	end

	def finalize
		while isRemainingTasks() do
			if ( isRunning() ) then
				sleep 0.1
			end
		end
		terminate()
	end

	def terminate
		@taskPool.clear()
		@threads.each do |aTaskExecutor|
			aTaskExecutor.terminate()
		end
	end
end

class ResultCollector
	def initialize(  )
		@result = []
		@_mutex = Mutex.new
	end

	def onResult( id, result )
		@_mutex.synchronize {
			if result.kind_of?(Array) then
				@result = @result | result
			else
				@result << result
			end
		}
	end

	def report()
		@_mutex.synchronize {
			@result.each do | aResult |
				puts "#{aResult}"
			end
		}
	end

	def getResult()
		result = nil
		@_mutex.synchronize {
			result = @result.clone()
		}
		return result
	end
end

class ResultCollectorHash < ResultCollector
	def initialize(  )
		super()
		@result = {}
	end

	def onResult( id, result )
		@_mutex.synchronize {
			@result[ id ] = result
		}
	end

	def report()
		@_mutex.synchronize {
			@result.each do | id, aResult |
				puts "#{id} : #{aResult}"
			end
		}
	end
end
