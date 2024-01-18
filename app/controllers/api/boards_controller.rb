class Api::BoardsController < ApplicationController
  extend ::NewRelic::Agent::MethodTracer
  before_action :require_api_token, :except => [:index, :user_index, :show, :simple_obf, :download]

  def index
    boards = Board
    if defined?(Octopus)
      conn = (Octopus.config[Rails.env] || {}).keys.sample
      boards = boards.using(conn) if conn
    end
    qp = request.query_parameters
    cache_key = nil
    if qp.keys.sort == ['locale', 'q', 'sort']
      if (params['q'] || '') == '' && params['locale'] && params['sort']
        cache_key = "board/search/#{params['locale']}/#{params['sort']}"
      end
    end
    if params['sort'] == 'popularity' && params['q'].blank?
      params['sort'] = 'home_popularity'
    end
    if cache_key
      json = RedisInit.default.get(cache_key)      
      if json && json != {}.to_json
        return render(json: json) 
      else
        RedisInit.default.setex(cache_key, 5.minutes.to_i, {}.to_json)
      end
    end
    start = Time.now.to_i
    boards = boards.includes(:board_content)
    other_boards = nil
    other_searchable_board_ids = nil

    Rails.logger.warn('checking key')
    self.class.trace_execution_scoped(['boards/key_check']) do
      if params['key']
        keys = [params['key']]
        if @api_user
          keys << "#{@api_user.user_name}/#{params['key']}"
        end
        boards = boards.where(:key => keys).limit(1)
      end
    end
    
    Rails.logger.warn('filtering by user')
    self.class.trace_execution_scoped(['boards/user_filter']) do
      if params['user_id']
        user = User.find_by_path(params['user_id'])
        return unless allowed?(user, 'view_detailed')
        unless params['starred'] || params['tag']
          if params['shared']
            Rails.logger.warn('looking up shared board ids')
            arel = Board.arel_table
            shared_board_ids = Board.all_shared_board_ids_for(user)
            # TODO: fix when sharding actually happens
            Rails.logger.warn('filtering by shared board ids')
            boards = boards.where(arel[:id].in(Board.local_ids(shared_board_ids)))
          elsif params['include_shared']
            arel = Board.arel_table
            Rails.logger.warn('looking up shared board ids 2')
            shared_board_ids = Board.all_shared_board_ids_for(user)
            # TODO: fix when sharding actually happens
            Rails.logger.warn('filtering by share board ids')
            boards = boards.where(arel[:user_id].eq(user.id).or(arel[:id].in(Board.local_ids(shared_board_ids))))
          else
            find_shallow_clones = false
            if !params['q'] && !params['locale'] && !params['public'] && !params['offset'] && user.allows?(@api_user, 'model')
              find_shallow_clones = true
            elsif params['q']
              find_shallow_clones = true
            end
            if find_shallow_clones
              shallow_clone_ids = []
              if user.settings['preferences'] && user.settings['preferences']['home_board'] && user.settings['preferences']['home_board']['id'].match(/-/)
                # Include the home board if it's a shallow clone
                shallow_clone_ids << user.settings['preferences']['home_board']['id']
              end
              if user.settings['preferences'] && (!user.settings['preferences']['home_board'] || user.settings['preferences']['sync_starred_boards'])
                # Include any shallow clone roots that are in the user's starred list
                shallow_clone_ids += user.starred_board_refs.select{|r| !r['suggested'] && r['key'] && r['key'].match(/^#{user.user_name}\/my:/) }.map{|c| c['id'] }
              end
              # Also include any shallow clone roots that have had a sub-board edited
              ue = UserExtra.find_by(user: user)
              if ue && ue.settings['replaced_roots']
                ue.settings['replaced_roots'].each do |id, hash|
                  shallow_clone_ids << hash['id']
                end
              end
              # Include in the results shallow clone roots that aren't currently owned by the user
              other_boards = Board.order('id DESC').find_all_by_global_id(shallow_clone_ids.uniq).select{|b| b.user_id != user.id } if shallow_clone_ids.length > 0
              if params['q'] && other_boards
                other_searchable_board_ids = other_boards.map(&:global_id) + other_boards.map{|b| b.downstream_board_ids }.flatten.uniq
                other_boards = nil
              end
            end
            boards = boards.where(:user_id => user.id)
          end
        end
        if !params['public']
          Rails.logger.warn('checking for supervision permission')
          return unless allowed?(user, 'model')
        end
        if params['private']
          Rails.logger.warn('checking for publicness')
          boards = boards.where(:public => false)
        end
        if params['starred'] || params['tag']
          Rails.logger.warn('filtering by user or public')
          ids = [user.id] + User.local_ids(user.supervised_user_ids)
          boards = boards.where(['user_id IN (?) OR public = ?',ids, true])
        end
        if params['starred']
          ids = (user.settings['starred_board_ids'] || [])
          Rails.logger.warn('filtering by starred board ids')
          boards = boards.where(:id => Board.local_ids(ids))
        end
        if params['tag']
          return unless allowed?(user, 'model')
          ids = []
          if user.user_extra
            ids = (user.user_extra.settings['board_tags'] || {})[params['tag']] || []
          end
          Rails.logger.warn('filtering by tagged board ids')
          boards = boards.where(:id => Board.local_ids(ids))
        end
      else
        params['public'] = true
      end
    end
    
    Rails.logger.warn('public query')
    ranks = {}
    self.class.trace_execution_scoped(['boards/public_query']) do
      if !params['q'].blank? && params['public']
        Rails.logger.warn('public blank lookup')
        q = CGI.unescape(params['q']).downcase
        locs = BoardLocale
        if !params['locale'].blank? && params['locale'] != 'any'
          locs = locs.where(locale: [params['locale'], params['locale'].split(/-|_/)[0]])
        end
        if params['user_id']
          board_ids = boards.select('id, board_content_id').limit(500).map(&:id)
          locs = locs.where(board_id: board_ids)
        end
        board_ids = []

        if params['sort'] == 'home_popularity'
          Rails.logger.warn('home_popularity search')
          locs.search_by_text_for_home_popularity(q).limit(100).with_pg_search_rank.each do |bl|
            board_ids << bl.board_id
            ranks[bl.board_id] = bl.pg_search_rank
          end
          # begin
          #   ActiveRecord::Base.connection.execute('set statement_timeout = 20000')
          #   # Do some long running queries
          # ensure
          #   # Always restore the statement_timeout to its initial value
          #   ActiveRecord::Base.connection.execute('set statement_timeout = 10000')
          # end          
        else
          Rails.logger.warn('popularity search')
          locs.search_by_text(q).limit(100).with_pg_search_rank.each do |bl|
            board_ids << bl.board_id
            ranks[bl.board_id] = 0 - (bl.pg_search_rank * (bl.popularity || 1))
          end
        end
        boards = boards.where(id: board_ids)
      end
    end
    if !params['locale'].blank? && params['locale'] != 'any' && (params['q'].blank? || !params['public'])
      if params['public']
        board_ids = []
        locs = BoardLocale.where(locale: [params['locale'], params['locale'].split(/-|_/)[0]])
        if params['sort'] == 'home_popularity'
          locs.order('home_popularity DESC, popularity DESC').limit(100).each_with_index do |bl, idx|
            board_ids << bl.board_id
            ranks[bl.board_id] = 100 - idx
          end
        else
          locs.order('popularity DESC, home_popularity DESC').limit(100).each_with_index do |bl, idx|
            board_ids << bl.board_id
            ranks[bl.board_id] = 100 - idx
          end
        end
        boards = boards.where(id: board_ids)
      else
        Rails.logger.warn('private locale search')
        lang = params['locale'].split(/-|_/)[0].downcase
        # board.search_string now includes locales, even on private boards
        # This filter should be applied for private searches (which wouldn't yet
        # have been filtered by locale) or for requests without a search query
        boards = boards.where(['search_string ILIKE ?', "%locale:#{lang}%"])
      end
    end

    Rails.logger.warn('public check')
    self.class.trace_execution_scoped(['boards/public_check']) do
      if params['public']
        boards = boards.where(:public => true)
      end
    end

    Rails.logger.warn('sort board')
    self.class.trace_execution_scoped(['boards/sort']) do
      if params['sort']
        if params['sort'] == 'popularity'
          boards = boards.order(popularity: :desc, home_popularity: :desc, id: :desc)
        elsif params['sort'] == 'home_popularity'
          if !params['user_id']
            boards = boards.where(['home_popularity > ?', 0]).order(home_popularity: :desc, id: :desc)
          else
            boards = boards.order(home_popularity: :desc, id: :desc)
          end
        elsif params['sort'] == 'custom_order'
          boards = boards[0, 100].sort_by{|b| b.settings['custom_order'] || b.id }
        end
      else
        boards = boards.order(popularity: :desc, any_upstream: :asc, id: :desc)
      end
    end
    
    Rails.logger.warn('starred filter')
    if params['exclude_starred']
      user = User.find_by_path(params['exclude_starred'])
      exclude_board_ids = []
      if user && user.settings['public']
        exclude_board_ids = user.settings['starred_board_ids'] || []
      end
      boards = boards.limit(100) if boards.respond_to?(:limit)
      boards = boards[0, 100].select{|b| !exclude_board_ids.include?(b.global_id) }
    end
    
    Rails.logger.warn('category filter')
    self.class.trace_execution_scoped(['boards/category']) do
      if params['category']
        boards = boards.limit(200) if boards.respond_to?(:limit)
        boards = boards[0, 200].select{|b| b.categories.include?(params['category']) }
      elsif params['copies'] == false || params['copies'] == 'false'
        if boards.respond_to?(:where)
          boards = boards.where('parent_board_id IS NULL')
        else
          boards = boards[0, 100].select{|b| !b.parent_board_id }[0, 100]
        end
        boards = boards.limit(100) if boards.respond_to?(:limit)
      end
    end

    if params['sort'] && params['sort'] != 'custom_order' && params['locale'] && params['locale'] != 'any'
      # All locale-defined lists should already have been filtered by locale
      # and search relevance, so we can safely trim to the top results here
      boards = boards.limit(50) if boards.respond_to?(:limit)
      # TODO: this was maybe too demanding on memory
      # boards = Board.sort_for_locale(boards[0, 50], params['locale'], params['sort'], ranks)
    end

    # Private boards don't have search_string set as a column to protect against 
    # leakage of private information. This iterative method is slower than a db clause
    # so we limit the possible result set to be more performant, which will only
    # be an issue for search users with very many boards (still problematic, I know)
    Rails.logger.warn('private query')
    progress = nil
    self.class.trace_execution_scoped(['boards/private_query']) do
      if params['root']
#        boards = boards.select{|b| !b.settings['copy_id'] || b.settings['copy_id'] == b.global_id }
        boards = boards.where(['search_string ILIKE ?', "%root%"])
      end

      if !params['q'].blank? && !params['public']
        limited_boards = boards
        if params['allow_job'] #&& boards.limit(26).select('id').length > 25
          progress = Progress.schedule(Board, :long_query, params['q'], params['locale'], boards.select('id, board_content_id').map(&:global_id) + (other_searchable_board_ids || []))
          boards = []
        else
          # For private user searches this will limit to the user's first 25 boards
          # since no search has been performed yet, so it will most likely
          # not be useful
          limited_boards = limited_boards.limit(15) if limited_boards.respond_to?(:limit)
          limited_boards = limited_boards[0, 15]
          boards = limited_boards
          # TODO: this was maybe too demanding on memory
          boards = Board.sort_for_query(limited_boards, params['q'], params['locale'], 0, 25)
        end
      end
    end
    
    json = nil
    Rails.logger.warn('start paginated result')
    self.class.trace_execution_scoped(['boards/json_paginate']) do
      json = JsonApi::Board.paginate(params, boards, {locale: params['locale'], extra_results: other_boards})
      json[:meta]['progress'] = JsonApi::Progress.as_json(progress) if progress
    end
    if cache_key
      RedisInit.default.setex(cache_key, 12.hours.to_i, json.to_json)
      json['uncached'] = true
    end

    if (Time.now.to_i - start) > 5
      Rails.logger.warn('extra-long-index')
    end

    render json: json
  end
  
  def show
    Rails.logger.warn('looking up board')
    board = nil
    # Octopus.using(:master) do
      # Followers can get behind, resulting in outdated info being
      # sent back to the user, or used for background jobs :-/
      board = Board.find_by_path(params['id'])
    # end
    if !board
      deleted_board = DeletedBoard.find_by_path(params['id'])
      # TODO: Sharding
      deleted_board ||= DeletedBoard.find_by(:id => (Board.local_ids([params['id']])[0] || 0))
      user = deleted_board && deleted_board.user
      res = {error: "Record not found"}
      res[:id] = params['id']
      if deleted_board && user && user.allows?(@api_user, 'view_deleted_boards')
        res[:deleted] = true
        res[:key] = deleted_board.key
        return api_error 404, res
      elsif params['id'].match(/\//)
        user = User.find_by_path(params['id'].split(/\//)[0])
        if user && user.allows?(@api_user, 'view_deleted_boards')
          res[:never_existed] = true
          return api_error 404, res
        end
      end
      return unless exists?(board)
    end
    allowed = false
    Rails.logger.warn('checking permission')
    self.class.trace_execution_scoped(['boards/board/permission_check']) do
      Rails.logger.warn("ACTION SHOW BOARD------------------------board: #{board}")
      allowed = allowed?(board, 'view')
      Rails.logger.warn("ACTION SHOW BOARD------------------------allowed: #{allowed}")
    end
    return unless allowed
    json = {}
    Rails.logger.warn('rendering json')
    self.class.trace_execution_scoped(['boards/board/json_render']) do
      board.track_usage!
      json = JsonApi::Board.as_json(board, :wrapper => true, :permissions => @api_user, :skip_subs => true)
    end
    Rails.logger.warn('rails render')
    render json: json.to_json
    Rails.logger.warn('done with controller')
  end
  
  def create
    @board_user = @api_user
    processed_params = params
    # Necessary because by default Rails is stripping out nil references in an array, which
    # messes up grid.order
    if request.content_type == 'application/json'
      processed_params = JSON.parse(request.body.read)
    end
    if processed_params['board'] && processed_params['board']['for_user_id'] && processed_params['board']['for_user_id'] != 'self'
      user = User.find_by_path(processed_params['board']['for_user_id'])
      return unless allowed?(user, 'edit')
      @board_user = user
    end
    opts = {:user => @board_user, :author => @api_user, :key => params['board']['key']}
    if processed_params['board'] && processed_params['board']['parent_board_id']
      pb = Board.find_by_path(processed_params['board']['parent_board_id'])
      if pb && pb.copyable_if_authorized?(@api_user)
        opts[:allow_copying_protected_boards] = true
      end
    end
    begin
      board = Board.process_new(processed_params['board'], opts)
    rescue ActiveRecord::RecordNotUnique
      return api_error(400, {error: 'board key already in use'})
    end
    if board.errored?
      api_error(400, {error: "board creation failed", errors: board && board.processing_errors})
    else
      render json: JsonApi::Board.as_json(board, :wrapper => true, :permissions => @api_user).to_json
    end
  end

  def rollback
    board_id = nil
    board = Board.find_by_path(params['board_id'])
    deleted_board = DeletedBoard.find_by_path(params['board_id'])
    return unless exists?(board || deleted_board, params['board_id'])
    allowed = @api_user.allows?(@api_user, 'admin_support_actions')
    date = Date.parse(params['date']) rescue nil
    return api_error 400, {error: 'invalid date'} unless date
    return api_error 400, {error: 'only 6 months history allowed'} unless date > 6.months.ago
    revert_date = nil
    restored = false
    if board
      return unless allowed || allowed?(board, 'edit')
    elsif deleted_board && deleted_board.user
      return unless allowed || allowed?(deleted_board.user, 'view_deleted_boards')
      revert_date = deleted_board.updated_at
      board = deleted_board.restore! rescue nil
      restored = true if board
    end
    if board
      revert_date = board.rollback_to(date)
    end
    render json: {board_id: board ? board.global_id : nil, key: board ? board.key : nil, restored: restored, reverted: revert_date.iso8601}
  end
  
  def share_response
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board)
    return unless allowed?(board, 'view')
    approve = !!(params['approve'] == 'true' || params['approve'] == true || params['approve'] == 1 || params['approve'] == '1')
    if board.update_shares_for(@api_user, approve)
      render json: {updated: true, approved: approve}.to_json
    else
      api_error(400, {error: "board share update failed"})
    end
  end
  
  def copies
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board)
    return unless allowed?(board, 'view')
    boards = board.find_copies_by(@api_user)
    render json: JsonApi::Board.paginate(params, boards)
  end
  
  def update
    board = Board.find_by_path(params['id'])
    if !board
      deleted_board = DeletedBoard.find_by_path(params['id'])
      deleted_board ||= DeletedBoard.find_by_path((params['board'] || {})['key'])
      if deleted_board && params['board'] && deleted_board.key == params['board']['key']
        # TODO: it should be allowable to restore a deleted board that has a different 
        # key, it should just use a different key instead
        user_name = deleted_board.key && deleted_board.key.split(/\//)[0]
        user = User.find_by_path(user_name)
        return unless allowed?(user, 'supervise')
        return allowed?(user, 'never_allow') if deleted_board.board
        board = Board.new
        board.id = deleted_board.board_id
        board.user = user
        board.key = deleted_board.key
        new_key = board.generate_unique_key(deleted_board.key)
        if new_key != board.key
          board.rename_to(new_key)
        end
        board.settings = {}
        board.settings['undeleted'] = true
        board.save
      end
    end    
    return unless exists?(board, params['id'])
    return unless allowed?(board, 'edit')
    processed_params = params
    # Necessary because by default Rails is stripping out nil references in an array, which
    # messes up grid.order
    if request.content_type == 'application/json'
      processed_params = JSON.parse(request.body.read)
    end
    res = false
    if processed_params['button']
      res = board.process_button(processed_params['button'])
    else
      version_date = Date.parse(request.headers['X-CoughDrop-Version']) rescue nil
      add_voc_error = version_date && version_date < Date.parse('August 3, 2021')
      new_board = board.process(processed_params['board'], {:allow_clone => true, :user => @api_user, :updater => @api_user, add_voc_error: add_voc_error})
      board = new_board if new_board.is_a?(Board)
      res = !!new_board
    end
    if res
      render json: JsonApi::Board.as_json(board, :wrapper => true, :permissions => @api_user).to_json
    else
      api_error(400, {error: "board update failed", errors: board && board.processing_errors})
    end
  end
  
  def history
    board_id = nil
    board = Board.find_by_path(params['board_id'])
    deleted_board = DeletedBoard.find_by_path(params['board_id'])
    return unless exists?(board || deleted_board)
    allowed = @api_user.allows?(@api_user, 'admin_support_actions')
    if board
      return unless allowed || allowed?(board, 'edit')
      board_id = board.global_id
    elsif deleted_board && deleted_board.user
      return unless allowed || allowed?(deleted_board.user, 'view_deleted_boards')
      board_id = deleted_board.board_global_id
    end
    return unless exists?(board_id)
    versions = Board.user_versions(board_id)
    render json: JsonApi::BoardVersion.paginate(params, versions, {:admin => Organization.admin_manager?(@api_user)})
  end
  
  def rename
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board)
    return unless allowed?(board, 'edit')
    if params['new_key'] && params['old_key'] == board.key && board.rename_to(params['new_key'])
      un, ky = params['new_key'].split(/\//, 2)
      key = "#{un}/#{Board.clean_path(ky)}"
      render json: {rename: true, key: key}.to_json
    else
      api_error(400, {error: "board rename failed", key: params['key'], collision: board.collision_error?})
    end
  end
  
  def unlink
    board = Board.find_by_path(params['board_id'])
    user = User.find_by_path(params['user_id'])
    type = params['type']
    return unless exists?(board)
    return unless allowed?(user, 'edit')
    if type == 'delete'
      return unless allowed?(board, 'delete')
      board.destroy
    elsif type == 'unstar'
      board.star!(user, false)
    elsif type == 'unlink'
      board.unshare_with(user)
    elsif type == 'untag'
      extra = user.reload.user_extra
      extra.tag_board(board, params['tag'], true, false) if extra
    else
      return api_error(400, {error: "unrecognized type"})
    end
    render json: {removed: true, type: type}.to_json
  end
  
  def star
    star_or_unstar(true)
  end

  def slice_locales
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'edit')
    progress = Progress.schedule(board, :slice_locales, params['locales'], params['ids_to_update'], (@api_user && @api_user.global_id))
    render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
  end

  def tag
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'view')
    extra = UserExtra.find_or_create_by(user: @api_user)
    res = extra.tag_board(board, params['tag'], params['remove'], params['downstream'])
    render json: {tagged: !!res, board_tags: res}
  end
  
  def unstar
    star_or_unstar(false)
  end
  
  def stats
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'view')
    render json: Stats.board_use(board.global_id, {}).to_json
  end

  def simple_obf
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'view')
    file = Tempfile.new(["board-#{board.global_id}", '.obf'])
    path = file.path
    file.close
    json = Converters::CoughDrop.to_external(board, {'simple' => true})
    OBF::External.to_obf(json, path, nil, {image_urls: true, sound_urls: true})
    send_data File.read(path), :type => 'application/obf', :disposition => 'attachment', :filename => "board-#{board.global_id}.obf"
  end
  
  def destroy
    board = Board.find_by_path(params['id'])
    return unless exists?(board)
    if board.instance_variable_get('@sub_id')
      return unless allowed?(board, 'edit')
      # Unstar and ensure it's not in replaced roots list (it shouldn't be)
      board.star!(board.instance_variable_get('@sub_global'), false)
      ue = UserExtra.find_by(user: board.instance_variable_get('@sub_global'))
      if ue && ue.settings['replaced_roots']
        ue.settings['replaced_roots'].delete(board.global_id(true))
        ue.save
      end
    else
      return unless allowed?(board, 'delete')
      if board.shallow_source
        ue = UserExtra.find_by(user: board.user)
        if ue && ue.settings['replaced_roots']
          ue.settings['replaced_roots'].delete(board.global_id(true))
          ue.save
        end
      end
      board.destroy
    end
    render json: JsonApi::Board.as_json(board, :wrapper => true).to_json
  end
  
  def download
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board)
    return unless allowed?(board, 'view')
    progress = Progress.schedule(board, :generate_download, (@api_user && @api_user.global_id), params['type'], {
      'include' => params['include'],
      'headerless' => params['headerless'] == '1',
      'text_on_top' => params['text_on_top'] == '1',
      'transparent_background' => params['transparent_background'] == '1',
      'symbol_background' => params['symbol_background'],
      'text_only' => params['text_only'] == '1',
      'text_case' => params['text_case'],
      'font' => params['font']
    })
    render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
  end
  
  def import
    if params['url']
      progress = Progress.schedule(Board, :import, @api_user.global_id, params['url'])
      render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
    else
      type = (params['type'] == 'obz' ? 'obz' : 'obf')
      remote_path = "imports/boards/#{@api_user.global_id}/upload-#{GoSecure.nonce('filename')}.#{type}"
      content_type = "application/#{type}"
      params = Uploader.remote_upload_params(remote_path, content_type)
      url = params[:upload_url] + remote_path
      params[:success_url] = "/api/v1/boards/imports?type=#{type}&url=#{CGI.escape(url)}"
      render json: {'remote_upload' => params}.to_json
    end
  end
  
  def translate
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'edit')
    ids = params['board_ids_to_translate'] || []
    ids << board.global_id
    translations = params['translations']
    translations = translations.to_unsafe_h if translations.respond_to?(:to_unsafe_h)
    set_as_default = true
    set_as_default = false if params['set_as_default'] == false || params['set_as_default'] == 'false' || params['set_as_default'] == 0 || params['set_as_default'] == '0'
    progress = Progress.schedule(board, :translate_set, translations, {
      'source' => params['source_lang'],
      'dest' => params['destination_lang'],
      'allow_fallbacks' => params['fallbacks'] == '1' || params['fallbacks'] == 'true' || params['fallbacks'] == true || params['fallbacks'] == 1,
      'board_ids' => ids,
      'default' => set_as_default,
      'user_key' => user_for_paper_trail
    })
    render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
  end

  def swap_images
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'edit')
    ids = params['board_ids_to_convert'] || []
    ids << board.global_id
    ids << "new:#{board.global_id}" if params['include_new']
    progress = Progress.schedule(board, :swap_images, params['library'], @api_user.global_id, ids)
    render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
  end

  def update_privacy
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'edit')
    ids = params['board_ids_to_update'] || []
    ids << board.global_id
    progress = Progress.schedule(board, :update_privacy, params['privacy'], @api_user.global_id, ids)
    render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
  end

  protected
  def star_or_unstar(star)
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'view')
    return unless exists?(@api_user)
    board.star!(@api_user, star)
    render json: {starred: board.starred_by?(@api_user), user_id: @api_user.global_id, stars: board.stars}.to_json
  end
  
end
