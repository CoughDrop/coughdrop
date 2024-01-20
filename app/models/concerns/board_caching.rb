module BoardCaching
  extend ActiveSupport::Concern
  
  # when to update this list for a user:
  # - board is shared/unshared with the user
  # - supervisee is added/removed
  # - authored/co-authored board is created, links modified, or changed to public/private
  # - board downstream of a authored/co-authored board is created, links modified, or changed to public/private
  # - board downstream of a downstream-shared board is created, links modified, or changed to public/private
  
  # explicitly-shared boards are viewable
  # the author's supervisors can view the author's boards
  # the user (and co-authors) should have edit and sharing access
  # the user and any of their editing supervisors should have edit access
  # the user should have edit and sharing access if a parent board is edit-shared including downstream with them
  # the user should have view access if the board is shared with any of their supervisees

  def update_available_boards
    # find all private boards authored by this user
    # TODO: sharding
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------self.settings['available_private_board_ids']: #{self.settings['available_private_board_ids']}")

    if self.settings && self.settings['available_private_board_ids'] && (self.settings['available_private_board_ids']['generated'] || 0) > 60.minutes.ago.to_i
      # Schedule for later if already run recently
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------self.settings['available_private_board_ids']['generated']: #{self.settings['available_private_board_ids']['generated']}")

      if (self.settings['available_private_board_ids']['view'] ||[]).length > 500
        ra_cnt = RemoteAction.where(path: self.global_id, action: 'update_available_boards').count
        Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------ra_cnt: #{ra_cnt}")
        
        RemoteAction.create(path: self.global_id, action: 'update_available_boards', act_at: 30.minutes.from_now) if ra_cnt == 0
        return
      end
    end

    self.settings ||= {}
    self.settings['available_private_board_ids'] ||= {
      'view' => [],
      'edit' => []
    }
    self.settings['available_private_board_ids']['generated'] = Time.now.to_i
    self.save(touch: false)
    authored = []
    Board.where(:public => false, :user_id => self.id).select('id').find_in_batches(batch_size: 200) do |batch|
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------batch: #{batch}")
      batch.each do |brd|
        authored << brd.global_id
        authored << brd.shallow_id if brd.shallow_id != brd.global_id
      end
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------authored: #{authored}")

    end
    # find all private boards shared with this user
    # find all private boards where this user is a co-author
    # find all private boards downstream of boards shared with this user
    # find all private boards downstream of boards edit-shared with this user
    self.clear_cached("all_shared_board_ids/true")
    self.clear_cached("all_shared_board_ids/false")
    view_shared = Board.all_shared_board_ids_for(self, false)
    edit_shared = Board.all_shared_board_ids_for(self, true)

    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------view_shared: #{view_shared}")
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------edit_shared: #{edit_shared}")



    # find all private boards available to this user's supervisees
    # find all private boards downstream of boards edit-shared with this user's supervisees
    supervisee_authored = []
    supervisee_view_shared = []
    supervisee_edit_shared = []
    self.supervisees.each do |sup| #.select{|s| self.edit_permission_for?(s) }.each do |sup|
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------sup, sup.private_viewable_board_ids, sup.private_editable_board_ids: #{sup}, #{sup.private_viewable_board_ids}, #{sup.private_editable_board_ids}")
      supervisee_view_shared += sup.private_viewable_board_ids 
      supervisee_edit_shared += sup.private_editable_board_ids if self.edit_permission_for?(sup)
#       # TODO: sharding
#       supervisee_authored += Board.where(:public => false, :user_id => sup.id).select('id').map(&:global_id)
#       supervisee_view_shared += Board.all_shared_board_ids_for(sup, false)
#       supervisee_edit_shared += Board.all_shared_board_ids_for(sup, true)
    end
    
    # generate a list of all private boards this user can edit/delete/share
    edit_ids = (authored + edit_shared + supervisee_authored + supervisee_edit_shared).uniq

    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------authored, edit_shared, supervisee_authored, supervisee_edit_shared, edit_ids: #{authored}, #{edit_shared}, #{supervisee_authored}, #{supervisee_edit_shared}, #{edit_ids}")

    # generate a list of all private boards this user can view
    view_ids = (edit_ids + view_shared + supervisee_view_shared).uniq
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------view_shared, supervisee_view_shared, edit_ids, view_ids: #{view_shared}, #{supervisee_view_shared}, #{edit_ids}, #{view_ids}")

    # TODO: sharding
    new_view_ids = []
    new_edit_ids = []
    added_edit_ids = []
    Board.where(:public => false, :id => self.class.local_ids(view_ids)).select('id').find_in_batches(batch_size: 100) do |batch|
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------batch: #{batch}")

      batch.each do |brd|
        new_view_ids << brd.global_id
        if edit_ids.include?(brd.global_id)
          new_edit_ids << brd.global_id 
          added_edit_ids << brd.global_id
        end
      end
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------new_view_ids, new_edit_ids, added_edit_ids: #{new_view_ids}, #{new_edit_ids}, #{added_edit_ids}")

    end
    view_ids = new_view_ids.sort
    Board.where(:id => self.class.local_ids(edit_ids - added_edit_ids)).select('id').find_in_batches(batch_size: 100) do |batch|
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------batch: #{batch}")
      batch.each do |brd|
        new_edit_ids << brd.global_id
      end
    end
    edit_ids = new_edit_ids.uniq.sort
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------edit_ids: #{edit_ids}")

    ab_json = self.settings['available_private_board_ids'].slice('view', 'edit').to_json
    self.settings['available_private_board_ids']['view'] = view_ids
    self.settings['available_private_board_ids']['edit'] = edit_ids
    self.settings['available_private_board_ids']['generated'] = Time.now.to_i
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------self.settings['available_private_board_ids']: #{self.settings['available_private_board_ids']}")

    # save those lists
    @do_track_boards = false
    self.boards_updated_at = Time.now
    Board.regenerate_shared_board_ids([self.global_id])
    self.assert_current_record!
    # if the lists changed, schedule this same update for all users
    # who would have been affected by a change (supervisors)
    if ab_json != self.settings['available_private_board_ids'].slice('view', 'edit').to_json
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------ab_json, self.settings['available_private_board_ids'].slice('view', 'edit').to_json: #{ab_json}, #{self.settings['available_private_board_ids'].slice('view', 'edit').to_json}")

      self.save_with_sync('board_list_changed')
      self.supervisors.each do |sup|
        Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------sup: #{sup}")

        ra_cnt = RemoteAction.where(path: sup.global_id, action: 'update_available_boards').count
        RemoteAction.create(path: sup.global_id, action: 'update_available_boards', act_at: 5.minutes.from_now) if ra_cnt == 0
      end
    else
      Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------else condition:")

      self.save
    end
  rescue ActiveRecord::StaleObjectError
    Rails.logger.warn("BOARD_CACHING update_available_boards-----------------------rescue condition:")

    self.schedule_once(:update_available_boards)
  end
  
  def private_viewable_board_ids
    self.settings ||= {}
    ((self.settings['available_private_board_ids'] || {})['view'] || [])
  end
  
  def private_editable_board_ids
    # kind of a lie, since it includes shared public boards as well
    self.settings ||= {}
    ((self.settings['available_private_board_ids'] || {})['edit'] || [])
  end
  
  def can_view?(board)
    private_viewable_board_ids.include?(board.global_id(true))
  end
  
  def can_edit?(board)
    private_editable_board_ids.include?(board.global_id(true))
  end
end

