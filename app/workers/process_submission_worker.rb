class ProcessSubmissionWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker
  sidekiq_options unique: :until_executed, queue: :default, retry: 5

  def perform(args)
    submission_id = args['submission_id']
    submission = Submission.by_id(submission_id).first
    return if submission.nil? || submission[:status_code] != 'PE'
    ext_hash = { 'c++' => '.cpp', 'java' => '.java', 'python' => '.py', 'python3' => '.py', 'c' => '.c', 'ruby' => '.rb' }
    problem = submission.problem
    contest = problem.contest
    testcases = problem.test_cases
    user_email = submission.user[:email]
    lang_code = submission.language[:lang_code]
    tlim = problem[:time_limit] * submission.language[:time_multiplier]
    mlim = problem[:memory_limit]
    diff_opt = problem[:diff]
    submission_path = "#{CONFIG[:base_path]}/users/#{user_email}/#{contest[:ccode]}/#{problem[:pcode]}/#{submission_id}/"
    judge_path = "#{CONFIG[:base_path]}/judge_exec/judge_exec"
    problem_path = "#{CONFIG[:base_path]}/contests/#{contest[:ccode]}/#{problem[:pcode]}/"
    judge_docker = CONFIG[:judge_docker]

    if !File.exist?(submission_path + "user_source_code#{ext_hash[lang_code]}") && !File.exist?(submission_path + "Main#{ext_hash[lang_code]}")
      submission.update!(status_code: 'CE', error_desc: 'CANNOT COMPILE CONTACT ADMIN')
      system 'rm', '-rf', submission_path
      return
    end
    compilation = nil
    if lang_code == 'c'
      compilation = " bash -c 'gcc -std=c++0x -lm -o compiled_code user_source_code#{ext_hash[lang_code]} >& compile_log'"
    elsif lang_code == 'c++'
      compilation = "bash -c 'g++ -std=c++0x -lm -o compiled_code user_source_code#{ext_hash[lang_code]} &> compile_log'"
    elsif lang_code == 'java'
      compilation = "bash -c 'javac Main#{ext_hash[lang_code]} &> compile_log'"
    elsif lang_code == 'python'
      compilation = "bash -c 'python -m py_compile user_source_code#{ext_hash[lang_code]} &> compile_log'"
    elsif lang_code == 'python3'
      compilation = "bash -c 'python3 -m py_compile user_source_code#{ext_hash[lang_code]} &> compile_log'"
    elsif lang_code == 'ruby'
      compilation = "bash -c 'ruby -wc user_source_code#{ext_hash[lang_code]} &> compile_log'"
    end

    if compilation.nil?
      submission.update!(status_code: 'CE', error_desc: 'CANNOT COMPILE CONTACT ADMIN')
      return
    end

    at 0, 'Compiling'

    pid = Process.spawn(compilation, chdir: submission_path)
    _, status = Process.wait2(pid)
    if !status.exited? || status.exitstatus != 0
      begin
        compile_log = File.read(submission_path + 'compile_log')
      rescue
        compile_log = 'compilation Error'
      end
      submission.update!(status_code: 'CE', error_desc: compile_log)
      at 100, 'done'
      return
    end

    time_taken = 0
    memory_taken = 0
    count = testcases.count
    if testcases.count == 0
      submission.update!(status_code: 'WA', error_desc: 'WA', time_taken: time_taken, memory_taken: memory_taken)
      return
    end
    percentage = (100 / count).to_i
    testcase_count = 0
    if judge_docker
      container_path = File.join(Rails.root, 'tmp', 'container')
      container_id = File.read(container_path).strip
    end
    testcases.each_with_index do |testcase, index|
      testcase_count += percentage
      at testcase_count, "judging (#{index + 1})"
      unless File.exist?("#{problem_path}#{testcase[:name]}/testcase")
        submission.update!(status_code: 'WA', error_desc: 'WA', time_taken: time_taken, memory_taken: memory_taken)
        return
      end
      execution = nil
      if judge_docker
        if lang_code == 'c' || lang_code == 'c++'
          execution = "bash -c \"docker exec #{container_id} bash -c '#{judge_path} --cpu #{tlim} --mem #{mlim} --usage #{submission_path}usage_log --exec #{submission_path}compiled_code < #{problem_path}#{testcase[:name]}/testcase > #{submission_path}#{testcase[:name]}/testcase_output'\""
        elsif lang_code == 'java'
          execution = "bash -c \"docker exec #{container_id} bash -c '#{judge_path} --cpu #{tlim} --mem #{mlim} --nproc 15  --usage #{submission_path}usage_log --exec /usr/bin/java -cp #{submission_path} Main < #{problem_path}#{testcase[:name]}/testcase > #{submission_path}#{testcase[:name]}/testcase_output'\""
        else
          execution = "bash -c \"docker exec #{container_id} bash -c '#{judge_path} --cpu #{tlim} --mem #{mlim} --usage #{submission_path}usage_log --exec /usr/bin/#{lang_code} #{submission_path}user_source_code#{ext_hash[lang_code]} < #{problem_path}#{testcase[:name]}/testcase > #{submission_path}#{testcase[:name]}/testcase_output'\""
        end
      else
        if lang_code == 'c' || lang_code == 'c++'
          execution = "bash -c 'sudo #{judge_path} --cpu #{tlim} --mem #{mlim} --usage #{submission_path}usage_log --exec #{submission_path}compiled_code < #{problem_path}#{testcase[:name]}/testcase' > #{submission_path}#{testcase[:name]}/testcase_output"
        elsif lang_code == 'java'
          execution = "bash -c 'sudo #{judge_path} --cpu #{tlim} --mem #{mlim} --nproc 50  --usage #{submission_path}usage_log --exec /usr/bin/java -cp #{submission_path} Main < #{problem_path}#{testcase[:name]}/testcase' > #{submission_path}#{testcase[:name]}/testcase_output"
        else
          execution = "bash -c 'sudo #{judge_path} --cpu #{tlim} --mem #{mlim} --usage #{submission_path}usage_log --exec /usr/bin/#{lang_code} #{submission_path}user_source_code#{ext_hash[lang_code]} < #{problem_path}#{testcase[:name]}/testcase' > #{submission_path}#{testcase[:name]}/testcase_output"
        end
      end
      pid = Process.spawn(execution)
      _, status = Process.wait2(pid)
      judge_usage = File.read(submission_path + 'usage_log')
      @judge_data = judge_usage.split("\n")
      time_taken += @judge_data[@judge_data.size - 1].to_f
      memory_taken += @judge_data[@judge_data.size - 2].to_i

      if @judge_data[0] == 'AC'
        user_output = submission_path + "#{testcase[:name]}/testcase_output"
        code_output = problem_path + "#{testcase[:name]}/testcase_output"
        if !File.exist?(user_output) || !File.exist?(code_output)
          submission.update!(status_code: 'WA', error_desc: 'WA', time_taken: time_taken, memory_taken: memory_taken)
          return
        end
        diff = `diff #{diff_opt} #{user_output} #{code_output}`
        unless diff.empty?
          @judge_data[0] = 'WA'
          submission.update!(status_code: 'WA', error_desc: 'WA', time_taken: time_taken, memory_taken: memory_taken)
          return
        end
      elsif @judge_data[0] == 'RTE'
        submission.update!(status_code: @judge_data[0], error_desc: @judge_data[1], time_taken: time_taken, memory_taken: memory_taken)
        return
      else
        submission.update!(status_code: @judge_data[0], time_taken: time_taken, memory_taken: memory_taken)
        return
      end
    end
    submission.update!(status_code: @judge_data[0], time_taken: time_taken, memory_taken: memory_taken)
    nil
  end
end
