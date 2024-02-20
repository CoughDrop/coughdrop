class BoardsController < ApplicationController
  def index
    @meta_record = OpenStruct.new
    @meta_record.title = "CoughDrop - Every voice should be heard"
    @meta_record.summary = "Let's help those with complex communication needs make their voices heard, using good technology that actually makes things easier and supports everyone in helping the individual succeed."
    if !@domain_overrides['settings']['full_domain']
      @meta_record.title = @domain_overrides['settings']['app_name']
      @meta_record.summary = "#{@domain_overrides['settings']['app_name']} is a flexible AAC application"
    end
    @meta_record.link = "#{request.protocol}#{request.host_with_port}/"
    @meta_record.created = Time.parse("Jan 1 2014").iso8601
    @meta_record.updated = Time.now.iso8601
    if request.headers['Accept'] == 'image/*'
      redirect_to '/images/logo-small.png'
    end
    
  end
  
  def about
    @meta_record = OpenStruct.new
    @meta_record.title = "About CoughDrop"
    @meta_record.summary = "Why \"CoughDrop\"? Cough drops help you get back the voice you already had, but that maybe people couldn't hear so well. If you're new to the world of augmentative communication, just about every part of it feels intimidating."
    if !@domain_overrides['settings']['full_domain']
      @meta_record.title = "About #{@domain_overrides['settings']['app_name']}"
      @meta_record.summary = "A little information about the #{@domain_overrides['settings']['app_name']} AAC application"
    end
    @meta_record.link = "#{request.protocol}#{request.host_with_port}/about"
    @meta_record.created = Time.parse("Jan 1 2014").iso8601
    @meta_record.updated = Time.now.iso8601
    render :index
  end
  
  def terms; end
  
  def privacy; end
  
  def utterance_redirect
    match = params['reply_code'].match(/^([0-9a-f]+)([A-Z]+)?$/)
    reply_code = match && match[1]
    utterance = Utterance.find_by(reply_nonce: reply_code)
    return redirect_to "/utterances/not_found" if !utterance
    return redirect_to "/utterances/expired" if utterance.created_at < 7.days.ago && !utterance.data['private_only']
    share_index = match[2]
    idx = Utterance.from_alpha_code(share_index) rescue nil
    return redirect_to "/utterances/not_found" if !idx || !(utterance.data['share_user_ids'] || [])[idx]
    redirect_to "/utterances/#{utterance.global_id}x#{utterance.reply_nonce}#{share_index}"
  end
  
  def log_goal_status
    if params['status']
      log = UserGoal.process_status_from_code(params['goal_id'], params['status'], params['goal_code'])
      if log
        redirect_to action: 'log_goal_status', result_status: params['status'], log_id: log.global_id
        return
      else
        @error = true
      end
    else
      @log = LogSession.find_by_global_id(params['log_id'])
    end
  end
  
  def board
    board = Board.find_by_possibly_old_path(params['id'])
    if board && board.old_link? && request.path != "/#{board.key}"
      return redirect_to "/#{board.key}"
    end
    @meta_record = board && board.public && board.meta_record
    if request.path.match(/\./)
      return redirect_to "/404"
      #raise ActiveRecord::RecordNotFound.new("Board paths can't have dots, so this is invalid: #{request.path}")
    end
    if params['embed']
      response.headers.except! 'X-Frame-Options'
    end
    render :index
  end

  def lesson
    @lesson = Lesson.find_by_path(params['lesson_id'])
    @lesson = nil unless @lesson.nonce == params['lesson_code']
    @user = User.find_by_token(params['user_token'])
    if !@user || !@lesson
      return redirect_to '/404'
    end
    render :index
    #render :lesson, :layout => false
  end
  
  def user
    user = User.find_by_possibly_old_path(params['id'])
    if user && user.old_link? && request.path != "/#{user.user_name}"
      return redirect_to "/#{user.user_name}"
    end
    @meta_record = user && user.settings['public'] && user.meta_record
    if request.path.match(/\./)
      return redirect_to "/404"
      #raise ActiveRecord::RecordNotFound.new("User paths can't have dots, so this is invalid: #{request.path}")
    end
    render :index
  end
  
  def cache
    response.headers.except! 'X-Frame-Options'
    render :layout => false
  end
  
  def video
    response.headers.except! 'X-Frame-Options'
    render :layout => false
  end

  def icon
    board = Board.find_by_path(params['id'])
    if board
      redirect_to board.icon_url_or_fallback
    else
      redirect_to Board::DEFAULT_ICON
    end
  end
  
  def utterance
    utterance = Utterance.find_by_global_id(params['id'])
    @meta_record = utterance && utterance.meta_record
    render :index
  end

  def jum_to_beta
    if params['access_token']
      u = User.find_by(user_name: params[:user_name])
      u.settings['current_web_version'] = ENV['CLASSIC_VIEW_HOST']
      u.save
      d = Device.find_or_create_by(:user_id => u.id, :developer_key_id => 0, :device_key => params[:device_key])
      render json: JsonApi::Token.as_json(u, d).to_json
    end
  end
end
