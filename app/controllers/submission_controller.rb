class SubmissionController < ApplicationController
  include Sidekiq::Status::Worker

  # TODO: add handle_unverified_request
  def index
    @title = 'Submission'
    @user_submission_page = true if params[:username] == current_user[:username]
    @submission_page = true
    query = get_query_from_params(params)
    @Submissions = Submission.by_query(query).order_by(created_at: -1).page(params[:page]).per(25)
    @test = params['test'] || false
    @Users = []
    @Contests = []
    @Problems = []
    @Submissions.each do |submission|
      user = submission.user
      problem = submission.problem
      @Users << { name: user[:name], user_id: user[:_id], email: user[:email], college: user[:college], username: user[:username] }
      @Problems << { name: problem[:pname], code: problem[:pcode] }
      @Contests << submission.problem.contest[:ccode]
    end
  end

  def verify_submission
    ccode = params[:ccode]
    pcode = params[:pcode]
    user_source_code = params[:user_source_code]
    language_name = params[:lang_name]
    language_code = params[:lang_code]
    test = params[:test]
    # language = Language.by_name(language_name).first
    language = Language.by_lang_code(language_code).first
    if language.nil?
      render(file: 'public/404.html', status: :not_found, layout: false) && return
    end
    contest = if test == 'true'
                Contest.by_code_test(ccode).first
              else
                Contest.by_code(ccode).first
               end
    if contest.nil?
      render(file: 'public/404.html', status: :not_found, layout: false) && return
    end
    if test != 'true'
      if contest[:start_time] > DateTime.now || contest[:end_time] < DateTime.now
        render(file: 'public/404.html', status: :not_found, layout: false) && return
      end
    else
      authorize! :read, contest
    end

    problem = if test == 'true'
                contest.problems.by_code_all(pcode).first
              else
                contest.problems.by_code(pcode).first
              end
    if problem.nil? || !(problem.languages.include? language)
      render(file: 'public/404.html', status: :not_found, layout: false) && return
    end
    source_limit = problem[:source_limit]
    if user_source_code.length > source_limit
      flash[:error] = 'source limit exceeded'
      if test == 'true'
        redirect_to(problem_path(ccode, pcode, test: true)) && return
      else
        redirect_to(problem_path(ccode, pcode)) && return
      end
    end
    unless user_signed_in?
      flash[:alert] = 'Please sign in  Or sign up first'
      redirect_to(new_user_session_path) && return
    end
    latest_submission = current_user.submissions.latest.pluck(:created_at).first
    unless latest_submission.nil?
      if DateTime.now.to_time - latest_submission.to_time < 30
        flash[:alert] = 'wait for 30s after the last submission'
        if test == 'true'
          redirect_to(problem_path(ccode, pcode, test: true)) && return
        else
          redirect_to(problem_path(ccode, pcode)) && return
        end
      end
    end
    submission = Submission.new(submission_time: DateTime.now, user_source_code: user_source_code, test: test)
    current_user.submissions << submission
    language.submissions << submission
    problem.submissions << submission
    if contest.users.by_id(current_user[:_id]).count == 0
      contest.users << current_user
    end
    submission.save!
    job_id = ProcessSubmissionWorker.perform_async(submission_id: submission[:_id].to_s)
    submission.update!(job_id: job_id)
    flash[:success] = 'sucessfully submitted'
    if test == 'true'
      redirect_to(submission_contest_path(ccode, test: true)) && return
    else
      redirect_to(submission_contest_path(ccode)) && return
    end
  end

  # TODO: fix 500 error on unauthorized access

  def get_submission_data
    submission = Submission.by_id(params['submission_id']).first
    authorize! :read, submission
    msg = if submission.nil?
            { error: 'bad submission' }
          else
            pe_status = Sidekiq::Status.message submission.job_id
            time_taken = submission[:time_taken].round(2) unless submission[:time_taken].nil?
            memory_taken = (submission[:memory_taken].to_f / 1000) .round(2) unless submission[:memory_taken].nil?
            { status_code: submission[:status_code], pe_status: pe_status, error_desc: submission[:error_desc], time_taken: time_taken.to_s, memory_taken: memory_taken.to_s }
          end
    respond_to do |format|
      format.json { render json: msg }
    end
  end

  # TODO: add authorization
  def get_submission
    submission = Submission.by_id(params['submission_id']).first
    authorize! :read, submission
    msg = if submission.nil?
            { error: 'wrong submission id' }
          else
            { lang_name: submission.language[:name], language: submission.language[:lang_code], user_source_code: submission[:user_source_code] }
          end
    respond_to do |format|
      format.json { render json: msg }
    end
  end

  # TODO: add authorization
  def get_submission_error
    submission = Submission.by_id(params['submission_id']).first
    authorize! :read, submission
    msg = if submission.nil?
            { error: 'wrong submission id' }
          else
            { error_desc: submission[:error_desc] }
          end
    respond_to do |format|
      format.json { render json: msg }
    end
  end

  def rejudge_submission
    submission_id = params['submission_id']
    submission = Submission.by_id(submission_id).first
    authorize! :read, submission
    msg = if submission.nil?
            { error: 'wrong submission id' }
          else
            { submit: 'true' }
          end
    submission.status_code = 'PE'
    submission.save!
    job_id = ProcessSubmissionWorker.perform_async(submission_id: submission[:_id].to_s)
    submission.update!(job_id: job_id)
    respond_to do |format|
      format.json { render json: msg }
    end
  end

  def rejudge_all_submission
    query = get_query_from_params(params)
    submissions = Submission.by_query(query).order_by(created_at: -1)
    authorization_check = submissions.all? { |submission| can? :update, submission }
    msg = if authorization_check
            submission_ids = submissions.pluck(:id).collect(&:to_s)
            RejudgeWorker.perform_async(submission_ids)
            { submit: 'true' }
          else
            { error: 'wrong submission id' }
          end
    respond_to do |format|
      format.json { render json: msg }
    end
  end

  private

  def get_query_from_params(params)
    username = params[:username]
    @ccode = params[:ccode]
    @pcode = params[:pcode]
    @test = params[:test] || false
    query = {}
    authorize! :read, Contest if @test
    unless @ccode.nil?
      @contest = if @test
                   Contest.by_code_test(@ccode).first
                 else
                   Contest.by_code(@ccode).first
                 end
      if @contest.nil?
        render(file: 'public/404.html', status: :not_found, layout: false) && return
      else
        if @pcode.nil?
          problem_ids = @contest.problems.map(&:_id)
          query.merge! ({ :problem_id.in => problem_ids })
        else
          problem = if @test
                      @contest.problems.by_code_all(@pcode).first
                    else
                      @contest.problems.by_code(@pcode).first
                    end
          if problem.nil?
            render(file: 'public/404.html', status: :not_found, layout: false) && return
          else
            @pname = problem[:pname]
            query.merge! ({ problem_id: problem[:_id] })
          end
        end
      end
    end
    unless username.nil?
      user = User.by_username(username).first
      if user.nil?
        render(file: 'public/404.html', status: :not_found, layout: false) && return
      else
        user_id = user._id
        @username = user[:username]
        @uname = user[:name]
        query.merge! ({ user_id: user_id })
      end
    end
    query.merge! ({ test: @test })
    query
  end
end
