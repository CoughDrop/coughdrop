class Board < ActiveRecord::Base
  DEFAULT_ICON = "https://s3.amazonaws.com/opensymbols/libraries/arasaac/board_3.png"
  include Processable
  include Permissions
  include Async
  include UpstreamDownstream
  include Relinking
  include GlobalId
  include MetaRecord
  include Notifier
  include SecureSerialize
  include Sharing
  include Renaming
  include PgSearch
  has_many :board_button_images
  has_many :button_images, :through => :board_button_images
  has_many :board_button_sounds
  has_many :button_sounds, :through => :board_button_sounds
  has_many :log_session_boards
  belongs_to :user
  belongs_to :parent_board, :class_name => 'Board'
  has_many :child_boards, :class_name => 'Board', :foreign_key => 'parent_board_id'
  pg_search_scope :search_by_text, :against => :search_string
  before_save :generate_defaults
  before_save :generate_stats
  before_save :require_key
  after_save :post_process
  after_destroy :flush_related_records
  
  has_paper_trail :only => [:current_revision, :settings, :name, :key, :public, :parent_board_id, :user_id],
                  :if => Proc.new{|b| PaperTrail.whodunnit && !PaperTrail.whodunnit.match(/^job/) }
  secure_serialize :settings

  # cache should be invalidated if:
  # - it is shared or unshared (including upstream)
  # - an author is added or removed (via sharing)
  # - it gains a new upstream link
  # - the author's supervision settings change
  # public boards anyone can view
  add_permissions('view', ['*']) { self.public }
  # check cached list of explicitly-allowed private boards
  add_permissions('view', ['read_boards']) {|user| !self.public && user.can_view?(self) }
  add_permissions('view', 'edit', 'delete', 'share') {|user| user.can_edit?(self) }
  # explicitly-shared boards are viewable
  add_permissions('view', ['read_boards']) {|user| self.shared_with?(user) } # should be redundant due to board_caching
  # the author's supervisors can view the author's boards
  # the user (and co-authors) should have edit and sharing access
  add_permissions('view', ['read_boards']) {|user| self.author?(user) } # should be redundant due to board_caching
  add_permissions('view', 'edit', 'delete', 'share') {|user| self.author?(user) } # should be redundant due to board_caching
  add_permissions('view', ['read_boards']) {|user| self.user && self.user.allows?(user, 'supervise') }
  # the user and any of their editing supervisors should have edit access
  add_permissions('view', ['read_boards']) {|user| self.user && self.user.allows?(user, 'edit') }
  add_permissions('view', 'edit', 'delete', 'share') {|user| self.user && self.user.allows?(user, 'edit') }
  # the user should have edit and sharing access if a parent board is edit-shared including downstream with them
  add_permissions('view', ['read_boards']) {|user| self.shared_with?(user, true) } # should be redundant due to board_caching
  add_permissions('view', 'edit', 'delete', 'share') {|user| self.shared_with?(user, true) } # should be redundant due to board_caching
  # the user should have view access if the board is shared with any of their supervisees
  add_permissions('view', ['read_boards']) {|user| user.supervisees.any?{|u| self.shared_with?(u) } } # should be redundant due to board_caching
  cache_permissions

  def starred_by?(user)
    !!(user && user.global_id && (self.settings['starred_user_ids'] || []).include?(user.global_id))
  end
  
  def star(user, star)
    self.settings ||= {}
    self.settings['starred_user_ids'] ||= []
    if user
      if star
        self.settings['starred_user_ids'] << user.global_id if user
        self.settings['starred_user_ids'].uniq!
      else
        self.settings['starred_user_ids'] = self.settings['starred_user_ids'] - [user.global_id]
      end
      self.settings['never_edited'] = false
      user.schedule(:remember_starred_board!, self.global_id)
    end
  end
  
  def star!(user, star)
    pre_whodunnit = PaperTrail.whodunnit
    PaperTrail.whodunnit = "job:star_user"
    self.star(user, star)
    res = self.save
    PaperTrail.whodunnit = pre_whodunnit
    res
  end
  
  def button_set_id
    id = self.settings && self.settings['board_downstream_button_set_id']
    if !id
      # TODO: sharding
      bs = BoardDownstreamButtonSet.select('id').find_by(:board_id => self.id)
      id = bs && bs.global_id
    end
    return nil unless id
    full_id = id + "_" + GoSecure.sha512(id, 'button_set_id')[0, 10]
  end
  
  def board_downstream_button_set
    if self.settings && self.settings['board_downstream_button_set_id']
      BoardDownstreamButtonSet.find_by_global_id(self.settings['board_downstream_button_set_id'])
    else
      BoardDownstreamButtonSet.find_by(:board_id => self.id)
    end
  end
  
  def non_author_starred?
    self.user && ((self.settings || {})['starred_user_ids'] || []).any?{|s| s != self.user.global_id }
  end
  
  def stars
    (self.settings || {})['stars'] || 0
  end
  
  def generate_stats
    self.settings['stars'] = (self.settings['starred_user_ids'] || []).length
    child_board_ids = self.child_boards.select('id').map(&:id)
    self.settings['forks'] = child_board_ids.length
    self.settings['home_forks'] = UserBoardConnection.where(:board_id => child_board_ids, :home => true).count
    self.settings['home_uses'] = UserBoardConnection.where(:board_id => self.id, :home => true).count
    self.settings['recent_home_uses'] = UserBoardConnection.where(['board_id = ? AND home = ? AND updated_at > ?', self.id, true, 30.days.ago]).count
    self.settings['recent_home_forks'] = UserBoardConnection.where(:board_id => child_board_ids).where(['home = ? AND updated_at > ?', true, 30.days.ago]).count
    self.settings['uses'] = UserBoardConnection.where(:board_id => self.id).count
    self.settings['recent_uses'] = UserBoardConnection.where(['board_id = ? AND updated_at > ?', self.id, 30.days.ago]).count
    self.settings['recent_forks'] = UserBoardConnection.where(:board_id => child_board_ids).where(['updated_at > ?', 30.days.ago]).count
    self.settings['non_author_uses'] = UserBoardConnection.where(['board_id = ? AND user_id != ?', self.id, self.user_id]).count
    self.settings['edit_key'] = Time.now.to_f.to_s + "-" + rand(9999).to_s
    if self.settings['never_edited']
      self.popularity = -1
      self.home_popularity = -1
    else
      # TODO: a real algorithm perchance?
      self.popularity = (self.settings['stars'] * 10) + self.settings['uses'] + (self.settings['forks'] * 2) + (self.settings['recent_uses'] * 3) + (self.settings['recent_forks'] * 3)
      self.home_popularity = (self.any_upstream ? 0 : 10) + (self.settings['stars'] * 3) + self.settings['home_uses'] + (self.settings['home_forks'] * 2) + (self.settings['recent_home_uses'] * 5) + (self.settings['recent_home_forks'] * 5)
    end
    self.any_upstream ||= false
    self.settings['total_buttons'] = (self.settings['buttons'] || []).length + (self.settings['total_downstream_buttons'] || 0)
    self.settings['unlinked_buttons'] = (self.settings['buttons'] || []).select{|btn| !btn['load_board'] }.length + (self.settings['unlinked_downstream_buttons'] || 0)
    if !self.settings['buttons'] || self.settings['buttons'].length == 0
      self.popularity = 0
      self.home_popularity = 0
    end
    true
  end

  def edit_key
    self.settings['edit_key']
  end
  
  def find_copies_by(user)
    if user
      ids = [user.id] + self.class.local_ids(user.supervised_user_ids || [])
      # TODO: sharding
      Board.where(:parent_board_id => self.id, :user_id => ids).sort_by{|b| [b.user_id == user.id ? 0 : 1, 0 - b.id] }
    else
      []
    end
  end
  
  def self.import(user_id, url)
    boards = []
    user = User.find_by_global_id(user_id)
    Progress.update_current_progress(0.05, :generating_boards)
    Progress.as_percent(0.05, 0.9) do
      boards = Converters::Utils.remote_to_boards(user, url)
    end
    asjson = boards.map{|b| JsonApi::Board.as_json(b, :permissions => user) }
    return asjson
  end
  
  def generate_download(user_id, type, opts)
    res = {}
    user = User.find_by_global_id(user_id)
    Progress.update_current_progress(0.03, :generating_files)
    Progress.as_percent(0.03, 0.9) do
      if ['obz', 'obf', 'pdf', 'csv'].include?(type.to_s)
        url = Converters::Utils.board_to_remote(self, user, {
          'file_type' => type.to_s,
          'include' => opts['include'] || 'this',
          'headerless' => !!opts['headerless'],
          'text_on_top' => !!opts['text_on_top'],
          'transparent_background' => !!opts['transparent_background'],
          'text_only' => !!opts['text_only'],
          'text_case' => opts['text_case'],
          'font' => opts['font']
        })
        if !url
          raise Progress::ProgressError, "No URL generated"
        end
        res = {:download_url => url}
      else
        raise Progress::ProgressError, "Unexpected download type, #{type}"
      end
    end
    return res
  end
  
  def generate_defaults
    self.settings ||= {}
    self.settings['name'] ||= "Unnamed Board"
    if !self.settings['image_url']
      self.settings['image_url'] = DEFAULT_ICON
      self.settings['default_image_url'] = DEFAULT_ICON
    elsif self.settings['image_url'] != self.settings['default_image_url']
      self.settings['default_image_url'] = nil
    end
    @brand_new = !self.id
    @buttons_changed = true if self.settings['buttons'] && !self.id
    @button_links_changed = true if (self.settings['buttons'] || []).any?{|b| b['load_board'] } && !self.id
    if @edit_description
      if self.settings['edit_description'] && self.settings['edit_description']['timestamp'] < @edit_description['timestamp'] - 1
        @edit_description = nil
      end
    end
    self.settings['edit_description'] = @edit_description
    @edit_description = nil

    self.settings['buttons'] ||= []
    self.settings['buttons'].each do |button|
      if button['load_board'] && button['load_board']['id'] && button['load_board']['id'] == self.related_global_id(self.parent_board_id) && @update_self_references == nil && !self.settings['self_references_updated']
        @update_self_references = true
      end
    end
    self.any_upstream = self.settings && self.settings['immediately_upstream_board_ids'] && self.settings['immediately_upstream_board_ids'].length > 0
    self.settings['grid'] ||= {}
    self.settings['grid']['rows'] = (self.settings['grid']['rows'] || 2).to_i
    self.settings['grid']['columns'] = (self.settings['grid']['columns'] || 4).to_i
    self.settings['grid']['order'] ||= []
    self.settings['grid']['rows'].times do |i|
      self.settings['grid']['order'][i] ||= []
      self.settings['grid']['columns'].times do |j|
        self.settings['grid']['order'][i][j] ||= nil
      end
      if self.settings['grid']['order'][i].length > self.settings['grid']['columns']
        self.settings['grid']['order'][i] = self.settings['grid']['order'][i].slice(0, self.settings['grid']['columns'])
      end
    end
    if self.settings['grid']['order'].length > self.settings['grid']['rows']
      self.settings['grid']['order'] = self.settings['grid']['order'].slice(0, self.settings['grid']['rows'])
    end
    if self.settings['grid']['labels'] && self.settings['buttons'].length == 0
      self.populate_buttons_from_labels(self.settings['grid'].delete('labels'), self.settings['grid'].delete('labels_order'))
    end
    update_immediately_downstream_board_ids
    
    data_hash = Digest::MD5.hexdigest(self.global_id.to_s + "_" + self.settings['grid'].to_json + "_" + self.settings['buttons'].to_json)
    self.settings['revision_hashes'] ||= []
    if !self.settings['revision_hashes'].last || self.settings['revision_hashes'].last[0] != data_hash
      @track_revision = [data_hash, Time.now.to_i]
      self.settings['revision_hashes'] << @track_revision
      self.current_revision = data_hash
    end
    
    self.settings['license'] ||= {type: 'private'}
    # self.name = self.settings['name']
    if self.protected_material?
      self.public = false unless self.settings['protected'] && self.settings['protected']['demo'] && !self.parent_board_id
    elsif self.public == nil
      if self.user && self.user.premium?
        self.public = false
      else
        self.public = true
      end
    end
          
    # TODO: encrypted search, lol
    self.settings['search_string'] = "#{self.settings['name']} #{self.settings['description'] || ""} #{self.key} #{self.labels} locale:#{self.settings['locale'] || ''}".downcase
    self.search_string = self.fully_listed? ? self.settings['search_string'] : nil
    true
  end
  
  def fully_listed?
    self.public && (!self.settings || !self.settings['unlisted'])
  end
  
  def protected_material?
    if self.settings && self.settings['protected']
      return true if self.settings['protected']['media'] || self.settings['protected']['vocabulary']
    end
    false
  end

  def labels
    return @labels if @labels
    list = []
    grid = self.settings['grid']
    buttons = self.settings['buttons']
    return "" if !grid || !buttons
    grid['columns'].times do |jdx|
      grid['rows'].times do |idx|
        id = grid['order'][idx] && grid['order'][idx][jdx]
        button = buttons.detect{|b| b['id'] == id }
        list.push(button['label']) if button && button['label']
      end
    end
    @labels = list.join(", ");
    return list.join(', ');
  end
  
  def current_revision
    self.attributes['current_revision'] || (self.settings && self.settings['revision_hashes'] && self.settings['revision_hashes'][-1] && self.settings['revision_hashes'][-1][0])
  end
  
  def full_set_revision
    self.settings['full_set_revision'] || self.current_revision || self.global_id
  end
  
  def populate_buttons_from_labels(labels, labels_order)
    labels_order ||= 'columns'
    max_id = self.settings['buttons'].map{|b| b['id'].to_i || 0 }.max || 0
    idx = 0
    labels.split(/\n|,\s*/).each do |label|
      label.strip!
      next if label.blank?
      max_id += 1
      button = {
        'id' => max_id,
        'label' => label,
        'suggest_symbol' => true
      }
      self.settings['buttons'] << button
      @buttons_changed = 'populated_from_labels'

      row = idx % self.settings['grid']['rows']
      col = (idx - row) / self.settings['grid']['rows']
      if labels_order == 'rows'
        col = idx % self.settings['grid']['columns']
        row = (idx - col) / self.settings['grid']['columns']
      end  

      if row < self.settings['grid']['rows'] && col < self.settings['grid']['columns']
        self.settings['grid']['order'][row][col] = button['id']
      end
      idx += 1
    end
  end
  
  def self.save_without_post_processing(board_ids)
    Board.find_all_by_global_id(board_ids).each do |board|
      board.save_without_post_processing if board
    end
  end
  
  def save_without_post_processing
    @skip_post_process = true
    self.save
    @skip_post_process = false
  end
  
  def post_process
    if @skip_post_process
      @skip_post_process = false
      return
    end
    
    rev = (((self.settings || {})['revision_hashes'] || [])[-2] || [])[0]
    notify('board_buttons_changed', {'revision' => rev, 'reason' => @buttons_changed}) if @buttons_changed && !@brand_new
    # Can't be backgrounded because board rendering depends on this
    self.map_images
    
    if self.settings && self.settings['image_url'] == DEFAULT_ICON && self.settings['default_image_url'] == self.settings['image_url'] && self.settings['name'] && self.settings['name'] != 'Unnamed Board'
      self.schedule(:check_image_url)
    end
    
    if @update_self_references
      self.update_self_references
    end
    
    if @check_for_parts_of_speech
      self.schedule(:check_for_parts_of_speech)
      @check_for_parts_of_speech = nil
    end
    schedule(:update_affected_users, @brand_new) if @button_links_changed || @brand_new

    schedule_downstream_checks
  end
  
  def update_self_references
    @update_self_references = false
    buttons = self.settings['buttons'] || []
    self.reload
    save_if_same_edit_key do
      self.settings['self_references_updated'] = true
      buttons.each do |button|
        if button['load_board'] && button['load_board']['id'] && button['load_board']['id'] == self.related_global_id(self.parent_board_id)
          button['load_board']['id'] = self.global_id
          button['load_board']['key'] = self.key
          @buttons_changed = 'updating_self_reference'
        end
      end
      self.settings['buttons'] = buttons
    end
  end
  
  def update_affected_users(is_new_board)
    # update user.content_changed_at based on UserBoardConnection 
    # (including supervisors of connected users)
    # TODO: sharding
    board_ids = [self.global_id]
    if is_new_board
      board_ids += (self.settings['immediately_upstream_board_ids'] || [])
    end
    # TODO: sharding
    ubcs = UserBoardConnection.where(:board_id => Board.local_ids(board_ids))
    root_users = ubcs.map(&:user).uniq
    more_user_ids = root_users.map(&:supervisor_user_ids).flatten.uniq
    user_ids = root_users.map(&:global_id) + more_user_ids
    
    # TODO: sharding
    users = User.where(:id => User.local_ids(user_ids))
    # TODO: finer-grained control, user.content_changed_at instead of just user.updated_at
    users.update_all(:updated_at => Time.now)
    # when a new board is created, call user.track_boards on all affected users 
    # (i.e. users with a connection to an upstream board)
    if is_new_board
      users.each do |user|
        user.track_boards('schedule')
      end
    end
  end
  
  def check_image_url
    if self.settings && self.settings['image_url'] == DEFAULT_ICON && self.settings['default_image_url'] == self.settings['image_url'] && self.settings['name'] && self.settings['name'] != 'Unnamed Board'
      res = Typhoeus.get("https://www.opensymbols.org/api/v1/symbols/search?q=#{CGI.escape(self.settings['name'])}", :ssl_verifypeer => false)
      results = JSON.parse(res.body) rescue nil
      results ||= []
      icon = results.detect do |result|
        result['license'] == "CC By" || result['repo_key'] == 'arasaac'
      end
      if icon && icon['image_url'] != DEFAULT_ICON
        # TODO race condition?
        self.update_setting({
          'image_url' => icon['image_url'],
          'default_image_url' => icon['image_url'],
          'default_image_details' => icon
        }, nil, :save_without_post_processing)
      end
    end
  end
  
  def map_images
    return unless @buttons_changed
    @buttons_changed = false
    @button_links_changed = false

    images = []
    sounds = []
    ((self.settings || {})['buttons'] || []).each do |button|
      images << {:id => button['image_id'], :label => button['label']} if button['image_id']
      sounds << {:id => button['sound_id']} if button['sound_id']
    end
    
    found_images = BoardButtonImage.images_for_board(self.id)
    existing_image_ids = found_images.map(&:global_id)
    existing_images = existing_image_ids.map{|id| {:id => id} }
    image_ids = images.map{|i| i[:id] }
    new_images = images.select{|i| !existing_image_ids.include?(i[:id]) }
    orphan_images = existing_images.select{|i| !image_ids.include?(i[:id]) }
    BoardButtonImage.connect(self.id, new_images, :user_id => self.user.global_id)
    BoardButtonImage.disconnect(self.id, orphan_images)

    found_sounds = BoardButtonSound.sounds_for_board(self.id)
    existing_sound_ids = found_sounds.map(&:global_id)
    existing_sounds = existing_sound_ids.map{|id| {:id => id} }
    sound_ids = sounds.map{|i| i[:id] }
    new_sounds = sounds.select{|i| !existing_sound_ids.include?(i[:id]) }
    orphan_sounds = existing_sounds.select{|i| !sound_ids.include?(i[:id]) }
    BoardButtonSound.connect(self.id, new_sounds, :user_id => self.user.global_id)
    BoardButtonSound.disconnect(self.id, orphan_sounds)
    
    if new_images.length > 0 || new_sounds.length > 0 || orphan_images.length > 0 || orphan_sounds.length > 0
      protected_images = ButtonImage.find_all_by_global_id(image_ids).select(&:protected?)
#      protected_images = BoardButtonImage.images_for_board(self.id).select(&:protected?)
      protected_sounds = ButtonSound.find_all_by_global_id(sound_ids).select(&:protected?)
#      protected_sounds = BoardButtonSound.sounds_for_board(self.id).select(&:protected?)
    
      self.settings ||= {}
      if (protected_images + protected_sounds).length > 0 && (self.settings['protected'] || {})['media'] != true
        # TODO: race condition?
        sources = protected_images.map{|i| i.settings['protected_source'] || 'lessonpix' }
        sources += protected_sounds.map{|s| s.settings['protected_source'] }
        sources = sources.compact.uniq
        self.update_setting({
          'protected' => {'media' => true, 'media_sources' => sources}
        }, nil, :save_without_post_processing)
      elsif (protected_images + protected_sounds).length == 0 && self.settings['protected'] && self.settings['protected']['media'] == true
        # TODO: race condition?
        if self.settings['protected']
          self.update_setting({
            'protected' => {'media' => false, 'media_sources' => []}
          }, nil, :save_without_post_processing)
        end
      end
    end
    @images_mapped_at = Time.now.to_i
  end
  
  def require_key
    # TODO: truncate long names
    self.key ||= generate_board_key(self.settings && self.settings['name'])
    true
  end
  
  def cached_user_name
    (self.key || "").split(/\//)[0]
  end
  
  def process_params(params, non_user_params)
    raise "user required as board author" unless self.user_id || non_user_params[:user]
    @edit_notes = []
    self.user ||= non_user_params[:user] if non_user_params[:user]
    if !params['parent_board_id'].blank?
      parent_board = Board.find_by_global_id(params['parent_board_id'])
      if !parent_board
        add_processing_error('parent board not found')
        return false
      elsif parent_board.protected_material? && !non_user_params[:allow_copying_protected_boards]
        add_processing_error('cannot copy protected boards')
        return false
      end
      self.parent_board = parent_board
    end
    self.settings ||= {}
    self.settings['last_updated'] = Time.now.iso8601
    @edit_notes << "renamed the board" if params['name'] && self.settings['name'] != params['name']
    self.settings['name'] = process_string(params['name']) if params['name']
    self.settings['word_suggestions'] = params['word_suggestions'] if params['word_suggestions'] != nil
    @edit_notes << "updated the description" if params['description'] && params['description'] != self.settings['description']
    self.settings['description'] = process_string(params['description']) if params['description']
    @edit_notes << "changed the image" if params['image_url'] && params['image_url'] != self.settings['image_url']
    self.settings['image_url'] = params['image_url'] if params['image_url']
    self.settings['locale'] = params['locale'] if params['locale']
    self.settings['home_board'] = params['home_board'] if params['home_board']
    self.settings['categories'] = params['categories'] if params['categories']
    self.settings['never_edited'] = false
    process_buttons(params['buttons'], non_user_params[:user], non_user_params[:author]) if params['buttons']
    prior_license = self.settings['license'].to_json
    process_license(params['license']) if params['license']
    @edit_notes << "changed the license" if self.settings['license'].to_json != prior_license
    self.star(non_user_params[:starrer], params['starred']) if params['starred'] != nil
    
    self.settings['grid'] = params['grid'] if params['grid']
    if params['visibility'] != nil
      if params['visibility'] == 'public'
        if !self.public || self.settings['unlisted']
          @edit_notes << "set to public"
          self.schedule_update_available_boards('all') if self.id
        end
        self.public = true
        self.settings['unlisted'] = false
      elsif params['visibility'] == 'unlisted'
        if !self.public || !self.settings['unlisted']
          @edit_notes << "set to unlisted"
          self.schedule_update_available_boards('all') if self.id
        end
        self.public = true
        self.settings['unlisted'] = true
      elsif params['visibility'] == 'private'
        if self.public
          @edit_notes << "set to private"
          self.schedule_update_available_boards('all') if self.id
        end
        self.public = false
        self.settings['unlisted'] = false
      end
    elsif params['public'] != nil
#       if self.public != false && params['public'] == false && (!self.user || !self.user.premium?)
#         add_processing_error("only premium users can make boards private")
#         return false
#       end
      @edit_notes << "set to public" if !!params['public'] && !self.public
      @edit_notes << "set to private" if !params['public'] && self.public
      if self.public != !!params['public'] && self.id
        self.schedule_update_available_boards('all')
      end
      self.public = !!params['public'] 
    end
    if !params['sharing_key'].blank?
      return false unless self.process_share(params['sharing_key'])
    end
    non_user_params[:key] = nil if non_user_params[:key].blank?
    if non_user_params[:key]
      non_user_params[:key].sub!(/^tmp\//, '')
      non_user_params[:key] = nil if non_user_params[:key].match(/^tmp_/)
      self.key = generate_board_key(non_user_params[:key]) if non_user_params[:key]
    end
#    @edit_description = nil
    if self.id && @edit_notes.length > 0
      @edit_description = {
        'timestamp' => Time.now.to_f,
        'notes' => @edit_notes
      }
    end
    true
  end
  
  def check_for_parts_of_speech!
    self.check_for_parts_of_speech
    self.save!
  end
  
  def check_for_parts_of_speech
    if self.settings && self.settings['buttons']
      any_changed = false
      # TODO: race condition?
      self.settings['buttons'].each do |button|
        word = button['vocalization'] || button['label']
        if word && !button['part_of_speech']
          speech ||= WordData.find_word(word)
          if speech && speech['types'] && speech['types'].length > 0
            button['part_of_speech'] = speech['types'][0]
            button['suggested_part_of_speech'] = speech['types'][0]
            any_changed = true
          end
        elsif button['part_of_speech'] && button['suggested_part_of_speech'] && button['part_of_speech'] != button['suggested_part_of_speech']
          str = "#{button['vocalization'] || button['label']}-#{button['part_of_speech']}"
          RedisInit.default.hincrby('overridden_parts_of_speech', str, 1) if RedisInit.default
        end
      end
      if any_changed
        self.assert_current_record!
        self.save 
      end
    end
  rescue ActiveRecord::StaleObjectError
    self.schedule_once(:check_for_parts_of_speech)
  end
  
  def process_button(button)
    found_button = (self.settings['buttons'] || []).detect{|b| b['id'].to_s == button['id'].to_s }
    if button['sound_id']
      found_button['sound_id'] = button['sound_id']
      @buttons_changed = 'button updated in-place'
    end
    self.schedule_once(:update_button_sets)
    self.save!
  end
  
  def update_button_sets
    upstreams = [self]
    visited_ids = []
    while upstreams.length > 0
      board = upstreams.shift
      BoardDownstreamButtonSet.schedule_once(:update_for, board.global_id)
      visited_ids << board.global_id
      ups = Board.find_all_by_global_id(board.settings['immediately_upstream_board_ids'])
      ups.each do |up|
        if !visited_ids.include?(up.global_id)
          upstreams.push(up)
        end
      end
    end
  end
  
  def process_buttons(buttons, editor, secondary_editor=nil)
    @edit_notes ||= []
    @check_for_parts_of_speech = true
    prior_buttons = self.settings['buttons'] || []
    approved_link_ids = []
    new_link_ids = []
    prior_buttons.each do |button|
      if button['load_board']
        approved_link_ids << button['load_board']['id']
        approved_link_ids << button['load_board']['key']
      end
    end
    self.settings['buttons'] = buttons.map do |button|
      trans = button['translations']
      button = button.slice('id', 'hidden', 'link_disabled', 'image_id', 'sound_id', 'label', 'vocalization', 
            'background_color', 'border_color', 'load_board', 'hide_label', 'url', 'apps', 
            'integration', 'video', 'book', 'part_of_speech', 'suggested_part_of_speech', 'external_id', 
            'painted_part_of_speech', 'add_to_vocalization', 'home_lock', 'blocking_speech');
      if button['load_board']
        if !approved_link_ids.include?(button['load_board']['id']) && !approved_link_ids.include?(button['load_board']['key'])
          link = Board.find_by_path(button['load_board']['id']) || Board.find_by_path(button['load_board']['key'])
          if !link || (!link.allows?(editor, 'view') && !link.allows?(secondary_editor, 'view'))
            button.delete('load_board')
          end
          new_link_ids << button['load_board']
        end
      end
      if trans
        self.settings['translations'] ||= {}
        trans.each do |tran|
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][tran['locale']] = tran.slice('label', 'vocalization')
        end
      end
      if button['part_of_speech'] && button['part_of_speech'] == ''
        button.delete('part_of_speech')
      end
      if !button['load_board'] && !button['apps'] && !button['url'] && !button['video']
        button.delete('link_disabled')
      end
      button
    end
    # TODO: for each button use tinycolor to compute a "safe" color for border and bg,
    # also a hover color for each, and mark them as "server-side approved"

    if self.settings['buttons'].to_json != prior_buttons.to_json
      @edit_notes << "modified buttons"
      @buttons_changed = 'buttons processed' 
      @button_links_changed = true if new_link_ids.length > 0
    end
    self.settings['buttons']
  end
  
  def icon_url_or_fallback
    fallback = DEFAULT_ICON
    self.settings['image_url'].blank? ? fallback : self.settings['image_url']
  end
  
  def rollback_board_set(date)
    boards = [self]
    downstreams = self.settings['downstream_board_ids']
    downs = Board.find_all_by_global_id(downstreams).select{|b| b.cached_user_name == self.cached_user_name }
    boards += downs
    boards.each do |board|
      puts "rolling back #{board.key} to #{date.to_s}"
      begin 
        board.rollback_to(date) 
      rescue => e
        puts "  rollback error, #{e.to_s}"
      end
    end
  end
  
  def flush_related_records
    DeletedBoard.process(self)
  end
  
  def buttons_and_images_for(user)
    key = "buttons_and_images/#{user ? user.cache_key : 'nobody'}"
    res = get_cached(key)
    return res if res
    res = {}
    bis = self.button_images
    ButtonImage.cached_copy_urls(bis, user)
    
    res['images'] = bis.map{|i| JsonApi::Image.as_json(i) }
    res['sounds'] = self.button_sounds.map{|s| JsonApi::Sound.as_json(s) }
    set_cached(key, res)
    res
  end

  def translate_set(translations, source_lang, dest_lang, board_ids, set_as_default=true, user_local_id=nil, visited_board_ids=[])
    user_local_id ||= self.user_id
    source_lang = 'en' if source_lang.blank?
    label_lang = dest_lang
    vocalization_lang = dest_lang
    return {done: true, translated: false, reason: 'mismatched user'} if user_local_id != self.user_id
    set_as_default_here = !!set_as_default
    set_as_default_here = false if self.settings['locale'] == label_lang
    if board_ids.blank? || board_ids.include?(self.global_id)
      if self.settings['name'] && translations[self.settings['name']] && set_as_default_here
        self.settings['name'] = translations[self.settings['name']]
      end
      self.settings['locale'] ||= source_lang
      self.settings['translations'] ||= {}
      self.settings['translations']['default'] ||= source_lang
      self.settings['translations']['current_label'] ||= source_lang
      self.settings['translations']['current_vocalization'] ||= source_lang
      if set_as_default_here
        self.settings['locale'] = label_lang
        self.settings['translations']['current_label'] = label_lang
        self.settings['translations']['current_vocalization'] = vocalization_lang
      end
      self.settings['buttons'].each do |button|
        if button['label'] && translations[button['label']]
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang]['label'] ||= button['label']
          self.settings['translations'][button['id'].to_s][dest_lang] ||= {}
          self.settings['translations'][button['id'].to_s][dest_lang]['label'] = translations[button['label']]
          button['label'] = translations[button['label']] if set_as_default_here
          @buttons_changed = 'translated'
        end
        if button['vocalization'] && translations[button['vocalization']]
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang]['vocalization'] ||= button['vocalization']
          self.settings['translations'][button['id'].to_s][dest_lang] ||= {}
          self.settings['translations'][button['id'].to_s][dest_lang]['vocalization'] = translations[button['vocalization']]
          button['vocalization'] = translations[button['vocalization']] if set_as_default_here
          @buttons_changed = 'translated'
        end
      end
      self.save
    else
      return {done: true, translated: false, reason: 'board not in list'}
    end
    visited_board_ids << self.global_id
    downstreams = self.settings['immediately_downstream_board_ids'] - visited_board_ids
    Board.find_all_by_path(downstreams).each do |brd|
      brd.translate_set(translations, source_lang, dest_lang, board_ids, set_as_default, user_local_id, visited_board_ids)
      visited_board_ids << brd.global_id
    end
    {done: true, translations: translations, d: dest_lang, s: source_lang, board_ids: board_ids, updated: visited_board_ids}
  end
  
  def swap_images(library, author, board_ids, user_local_id=nil, visited_board_ids=[], updated_board_ids=[])
    author = User.find_by_global_id(author) if author && author.is_a?(String)
    user_local_id ||= self.user_id
    return {done: true, swapped: false, reason: 'mismatched user'} if user_local_id != self.user_id
    return {done: true, swapped: false, reason: 'no library specified'} if !library || library.blank?
    if (board_ids.blank? || board_ids.include?(self.global_id))
      updated_board_ids << self.global_id
      self.settings['buttons'].each do |button|
        if button['label'] || button['vocalization']
          image_data = Uploader.find_images(button['label'] || button['vocalization'], library, author)[0]
          if image_data
            bi = ButtonImage.process_new(image_data, {user: author})
            button['image_id'] = bi.global_id
            @buttons_changed = 'swapped images'
          end
        end
      end
      self.save if @buttons_changed
    else
      return {done: true, swapped: false, reason: 'board not in list'}
    end
    visited_board_ids << self.global_id
    downstreams = self.settings['immediately_downstream_board_ids'] - visited_board_ids
    Board.find_all_by_path(downstreams).each do |brd|
      brd.swap_images(library, author, board_ids, user_local_id, visited_board_ids, updated_board_ids)
      visited_board_ids << brd.global_id
    end
    {done: true, library: library, board_ids: board_ids, visited: visited_board_ids.uniq, updated: updated_board_ids.uniq}
  end  
  
  def default_listeners(notification_type)
    if notification_type == 'board_buttons_changed'
      ubc = UserBoardConnection.where(:board_id => self.id)
      direct_users = ubc.map(&:user)
      supervisors = direct_users.map(&:supervisors).flatten
      (direct_users + supervisors).uniq.map(&:record_code)
    else
      []
    end
  end
  
  def additional_webhook_record_codes(notification_type, additional_args)
    if notification_type == 'button_action' && additional_args && additional_args['button_id']
      button = self.settings['buttons'].detect{|b| b['id'].to_s == additional_args['button_id'].to_s }
      user = additional_args && User.find_by_path(additional_args['user_id'])
      res = []
      if button && button['integration'] && button['integration']['user_integration_id'] && self.allows?(user, 'view')
        ui = UserIntegration.find_by_path(button['integration']['user_integration_id'])
        res << ui.record_code if ui && ui.settings['button_webhook_url']
      end
      res
    else
      []
    end
  end
  
  def webhook_content(notification_type, content_type, additional_args)
    if notification_type == 'button_action' && additional_args && additional_args['button_id']
      button = self.settings['buttons'].detect{|b| b['id'].to_s == additional_args['button_id'].to_s }
      res = {}
      user = additional_args && User.find_by_path(additional_args['user_id'])
      if button && button['integration'] && button['integration']['user_integration_id'] && self.allows?(user, 'view')
        ui = UserIntegration.find_by_path(button['integration']['user_integration_id'])
        associated_user = additional_args && User.find_by_path(additional_args['associated_user_id'])
        associated_user = nil if associated_user && !associated_user.allows?(user, 'supervise')
        if ui && ui.settings['button_webhook_url']
          placement_code = ui.placement_code(self.global_id, button['id'].to_s)
          ref_user = associated_user || user
          user_code = ui.placement_code(ref_user ? ref_user.global_id : "nobody")
          res = {
            'action' => button['integration']['action'],
            'placement_code' => placement_code,
            'user_code' => ref_user ? user_code : nil
          }
          if user && ui.allow_private_information?
            res['user_id'] = user.global_id
            res['board_id'] = board.global_id
            res['button_id'] = button['id']
            res['associated_user_id'] = associated_user.global_id if associated_user
          end
        end
      end
      res.to_json
    else
      {}.to_json
    end
  end
end
