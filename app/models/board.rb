class Board < ActiveRecord::Base
  DEFAULT_ICON = "https://opensymbols.s3.amazonaws.com/libraries/arasaac/board_3.png"
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

  has_many :board_button_images
  # has_many :button_images, :through => :board_button_images
  has_many :board_button_sounds
  has_many :button_sounds, :through => :board_button_sounds
  has_many :log_session_boards
  belongs_to :user
  belongs_to :parent_board, :class_name => 'Board'
  belongs_to :board_content
  has_many :child_boards, :class_name => 'Board', :foreign_key => 'parent_board_id'
  # pg_search_scope :search_by_text, :against => :search_string, :ranked_by => "log(boards.popularity + boards.home_popularity + 3) * :tsearch"
  # pg_search_scope :search_by_text_for_home_popularity, :against => :search_string, :ranked_by => "log(boards.home_popularity + 2) * :tsearch"
  before_save :generate_defaults
  before_save :require_key
  before_save :check_inflections
  before_save :check_content_overrides
  after_save :post_process
  after_save :assert_shallow_mapping
  after_destroy :flush_related_records
#  replicated_model
 
  has_paper_trail :only => [:current_revision, :settings, :name, :key, :public, :parent_board_id, :user_id, :board_content_id],
                  :if => Proc.new{|b| PaperTrail.request.whodunnit && !PaperTrail.request.whodunnit.match(/^job/) }
  secure_serialize :settings

  # cache should be invalidated if:
  # - it is shared or unshared (including upstream)
  # - an author is added or removed (via sharing)
  # - it gains a new upstream link
  # - the author's supervision settings change
  # public boards anyone can view
  add_permissions('view', ['*']) { self.public && !@sub_id }
  # check cached list of explicitly-allowed private boards
  add_permissions('view', ['read_boards']) {|user| !self.public && user.can_view?(self) }
  add_permissions('view', 'edit', 'delete', 'share') {|user| user.can_edit?(self) }
  # for a shallow clone, you need read permission on the original, and model permission on the shallow user
  add_permissions('view') {|user| @sub_id && (self.public || @sub_global.can_view?(self)) && @sub_global.allows?(user, 'model') }
  add_permissions('view', 'edit') {|user| @sub_id && (self.public || @sub_global.can_view?(self)) && @sub_global.allows?(user, 'edit_boards') }
  # explicitly-shared boards are viewable
#  add_permissions('view', ['read_boards']) {|user| self.shared_with?(user) } # should be redundant due to board_caching
  # the author's supervisors can view the author's boards
  # the user (and co-authors) should have edit and sharing access
#  add_permissions('view', ['read_boards']) {|user| self.author?(user) } # should be redundant due to board_caching
#  add_permissions('view', 'edit', 'delete', 'share') {|user| self.author?(user) } # should be redundant due to board_caching
  add_permissions('view', ['read_boards']) {|user| !@sub_id && self.user && self.user.allows?(user, 'model') }
  # the user and any of their editing supervisors/org admins should have edit access
  add_permissions('view', ['read_boards']) {|user| !@sub_id && self.user && self.user.allows?(user, 'edit') }
  add_permissions('view', 'edit', 'delete', 'share') {|user| !@sub_id && self.user && self.user.allows?(user, 'edit_boards') }
  # the user should have edit and sharing access if a parent board is edit-shared including downstream with them
#  add_permissions('view', ['read_boards']) {|user| self.shared_with?(user, true) } # should be redundant due to board_caching
#  add_permissions('view', 'edit', 'delete', 'share') {|user| self.shared_with?(user, true) } # should be redundant due to board_caching
  # the user should have view access if the board is shared with any of their supervisees
#  add_permissions('view', ['read_boards']) {|user| user.supervisees.any?{|u| self.shared_with?(u) } } # should be redundant due to board_caching
  cache_permissions

  def key(actual=false)
    orig_key = read_attribute('key')
    if @sub_id && @sub_global && !actual
      return "#{@sub_global.user_name}/my:#{orig_key.sub(/\//, ':')}"
    else
      return orig_key
    end
  end

  def shallow_source
    if self.settings && self.settings['shallow_source']
      return {
        key: self.settings['shallow_source']['key'],
        id: self.settings['shallow_source']['id'],
      }
    end
    return nil
  end

  def shallow_id
    (shallow_source || {})[:id] || self.global_id
  end

  def shallow_key
    (shallow_source || {})[:key] || self.key
  end

  def downstream_board_ids
    res = (self.settings || {})['downstream_board_ids'] || []
    if @sub_id && @sub_global
      ue = @sub_global.user_extra
      ids = []
      lookup_ids = []
      res.each do |id|
        new_id = "#{id}-#{@sub_id}"
        ids << new_id
        if ue && ue.settings['replaced_boards'] && ue.settings['replaced_boards'][id]
          lookup_ids << new_id #ue.settings['replaced_boards'][id]

        end
      end
      Board.find_all_by_global_id(lookup_ids).each do |brd|
        ids += brd.downstream_board_ids
      end
      res = ids
    end
    res - [self.global_id]
  end

  def user(true_user=false)
    if @sub_global && !true_user
      @sub_global
    else
      super
    end
  end

  def cache_key(prefix=nil)
    id = (self.respond_to?(:global_id) && self.global_id) || self.id || 'nil'
    updated = (self.updated_at || Time.now).to_f
    key = "#{self.class.to_s}#{id}-#{updated}:#{Permissable.cache_token}"
    if prefix
      key = prefix + "/" + key
    end
    key
  end  

  def starred_by?(user)
    user_id = user
    if !user.is_a?(String)
      user_id = user && user.global_id
      user_id = 'bump' if user && user.user_name == 'star_bump'
    end
    !!(user && user_id && !!(self.settings['starred_user_ids'] || []).detect{|id| id == user_id || id.to_s.match(/.+:#{user_id}/) })
  end
  
  def star(user, star, locale=nil)
    board = self
    if @sub_id
      # shallow clones cannot be saved
      board = Board.find_by(id: board.id)
    end
    board.settings ||= {}
    locale ||= board.settings['locale'] || 'en'
    board.settings['starred_user_ids'] ||= []
    if user
      user_id = user.global_id
      user_id = 'bump' if user.user_name == 'star_bump'
      if star
        if !starred_by?(user)
          board.settings['starred_user_ids'] << "#{locale}:#{user_id}"
        end
      else
        board.settings['starred_user_ids'] = board.settings['starred_user_ids'].select{|id| id != user_id && !id.to_s.match(/.+:#{user_id}/) }
      end
      board.settings['never_edited'] = false
      board.generate_stats
      user.schedule(:remember_starred_board!, self.shallow_id)
    end
    board
  end

  def star!(user, star)
    pre_whodunnit = PaperTrail.request.whodunnit
    PaperTrail.request.whodunnit = "job:star_user"
    board = self.star(user, star)
    res = board.save
    self.reload if @sub_id
    PaperTrail.request.whodunnit = pre_whodunnit
    res
  end
  
  def button_set_id
    if @sub_id
      bs = BoardDownstreamButtonSet.find_by(:board_id => self.id, :user_id => User.local_ids([@sub_id])[0])
      id = bs && bs.global_id
    else
      id = self.settings && self.settings['board_downstream_button_set_id']
      if !id
        # TODO: sharding
        bs = BoardDownstreamButtonSet.select('id').find_by(:board_id => self.id)
        id = bs && bs.global_id
      end
    end
    return nil unless id
    full_id = id + "_" + GoSecure.sha512(id, 'button_set_id')[0, 10]
  end
  
  def board_downstream_button_set
    bs = nil
    if @sub_id
      bs = BoardDownstreamButtonSet.find_by(:board_id => self.id, :user_id => User.local_ids([@sub_id])[0])
    elsif self.settings && self.settings['board_downstream_button_set_id']
      bs = BoardDownstreamButtonSet.find_by_global_id(self.settings['board_downstream_button_set_id'])
    else
      bs = BoardDownstreamButtonSet.find_by(:board_id => self.id, user_id: nil)
    end
    bs.assert_extra_data if bs
    bs
  end

  def source_board
    # Source board is the originally-created board that this was probably copied from
    res = nil
    if self.settings && self.settings['source_board_id']
      res = Board.find_by_path(self.settings['source_board_id'])
    end
    res ||= self
    while res.parent_board
      res = res.parent_board
    end
    res
  end

  def root_board
    # Root board is the most-likely home board, or where the user started to get to this board
    if self.settings['home_board']
      return self
    elsif self.settings['copy_id']
      copy_id = self.settings['copy_id']
      return self if copy_id == self.global_id
      # Make sure to factor in @sub_id information
      if self.shallow_source
        return Board.find_by_global_id("#{copy_id}-#{self.related_global_id(self.user_id)}")
      elsif @sub_id
        return Board.find_by_global_id("#{copy_id}-#{@sub_global.global_id}")
      else
        return Board.find_by_global_id(copy_id)
      end
    else
      return self
    end
  end

  def track_usage!
    if self.public && self.home_popularity && self.settings && self.settings['home_board']
      # TODO: increment counter for this board with an expiration
      #    If the counter gets high enough, mark this as a common board
      #    and try to optimize for future use
      # TODO: also in that case, schedule an action to map all of the symbol libraries
      #    for the board set to get even faster symbol switching
    end
  end

  def self.find_suggested(locale='en', limit=10)
    ids = nil
    if locale == 'en'
      user = User.find_by_path('example')
      ids = user && self.local_ids(user.settings['starred_board_ids'] || [])
    end
    if ids.blank?
      locs = BoardLocale.where(locale: [locale, locale.split(/-|_/)[0]])
      ids = locs.order('home_popularity DESC, popularity DESC').limit(limit).map{|bl| bl.board_id }
    end
    Board.where(id: ids).where('home_popularity > ?', 0).order('home_popularity DESC, popularity DESC').limit(limit)
  end
  
  def non_author_starred?
    self.user && ((self.settings || {})['starred_user_ids'] || []).any?{|s| s != self.user.global_id && !s.to_s.match(self.user.global_id) }
  end
  
  def stars
    (self.settings || {})['stars'] || ((self.settings || {})['starred_user_ids'] || []).length
  end

  def self.refresh_stats(board_ids, timestamp=nil)
    stash = nil
    if board_ids.is_a?(Hash) && board_ids['stash']
      stash = JobStash.find_by_global_id(board_ids['stash'])
      board_ids = stash.data
    end
    now = Time.now.to_i
    timestamp ||= now
    more_board_ids = []
    board_ids.each do |board_id|
      # Prevent these jobs from running too long and clogging the queue
      if Time.now.to_i > now + 3.minutes.to_i
        more_board_ids << board_id
      else
        board = Board.find_by_global_id(board_id)
        if board && board.updated_at.to_i < timestamp && (board.public || board.settings['unlisted'])
          board.generate_stats
          board.save_without_post_processing
        end
        upper = board && board.parent_board
        if upper && upper != board && upper.updated_at.to_i < timestamp && (upper.public || upper.settings['unlisted'])
          upper.generate_stats
          upper.save_without_post_processing
        end        
      end
    end
    if more_board_ids.length > 0
      stash ||= JobStash.create
      stash.data = more_board_ids.uniq
      stash.save
      Board.schedule_for(:slow, :refresh_stats, {'stash' => stash.global_id}, timestamp)
    elsif stash
      stash.destroy
    end
  end

  def generate_stats(frd=false)
    self.settings['stars'] = (self.settings['starred_user_ids'] || []).length
    self.settings['locale_stars'] = {}
    @button_images = nil
    pops = {}
    home_pops = {}
    locales = []
    (BoardContent.load_content(self, 'translations') || {}).each do |k, trans|
      if trans.is_a?(Hash)
        locales += trans.keys.compact
      end
    end
    locales.uniq!
    (self.settings['starred_user_ids'] || []).select{|s| s.to_s.match(/:/) }.each do |str|
      loc = str.split(/:/)[0]
      self.settings['locale_stars'][loc] ||= 0
      self.settings['locale_stars'][loc] += 1
      if loc.match(/-|_/)
        lang = loc.split(/-|_/)[0]
        self.settings['locale_stars'][lang] ||= 0
        self.settings['locale_stars'][lang] += 1
      end
    end
    child_board_ids = self.child_boards.select('id').map(&:id)
    self.settings['forks'] = child_board_ids.length
    if child_board_ids.length > 10 && !frd
      self.schedule_for(:slow, :generate_stats, true)
    else
      # This was getting too slow to be allowed in-request
      child_conns = UserBoardConnection.where(:board_id => child_board_ids)
      self.settings['locale_home_forks'] = {}
      self.settings['non_author_uses'] = 0
      if child_conns.count > 20
        self.settings['home_forks'] = child_conns.where(home: true).count
        self.settings['recent_forks'] = child_conns.where(['updated_at > ?', 30.days.ago]).count
        self.settings['recent_home_forks']  = child_conns.where(home: true).where(['updated_at > ?', 30.days.ago]).count
        self.settings['non_author_uses'] += child_conns.where(['user_id != ?', self.user_id]).count
        child_conns.where('locale IS NULL').each do |ubc|
          if !ubc.locale && ubc.board && ubc.board.settings
            UserBoardConnection.where(id: ubc.id).update_all(locale: ubc.board.settings['locale'])
            ubc.locale = ubc.board.settings['locale']
          end
        end
        child_conns.where(home: true).group('locale').count('home').each do |lang, count|
          loc = (lang || 'en').split(/_|-/)[0]
          self.settings['locale_home_forks'][lang] = (self.settings['locale_home_forks'][lang] || 0) + count
          self.settings['locale_home_forks'][loc] = (self.settings['locale_home_forks'][loc] || 0) + count if lang != loc
        end
      else
        self.settings['home_forks'] = 0
        self.settings['recent_forks'] = 0
        self.settings['recent_home_forks'] = 0
        child_conns.each do |ubc|
          if !ubc.locale && ubc.board && ubc.board.settings
            UserBoardConnection.where(id: ubc.id).update_all(locale: ubc.board.settings['locale'])
            ubc.locale = ubc.board.settings['locale']
          end
          loc = (ubc.locale || 'en').split(/_|-/)[0]
          self.settings['home_forks'] += 1 if ubc.home
          self.settings['locale_home_forks'][ubc.locale] = (self.settings['locale_home_forks'][ubc.locale] || 0) + 1 if ubc.home
          self.settings['locale_home_forks'][loc] = (self.settings['locale_home_forks'][loc] || 0) + 1 if ubc.home && ubc.locale != loc
          if ubc.updated_at > 30.days.ago
            self.settings['recent_forks'] += 1 
            self.settings['recent_home_forks'] += 1 if ubc.home        
          end
        end
        self.save if frd
        true
      end
    end
      
    conns = UserBoardConnection.where(:board_id => self.id)
    self.settings['locale_home_uses'] = {}
    if conns.count > 20
      self.settings['home_uses'] = conns.where(home: true).count
      self.settings['recent_home_uses'] = conns.where(home: true).where(['updated_at > ?', 30.days.ago]).count
      self.settings['uses'] = conns.count
      self.settings['recent_uses'] = conns.where(['updated_at > ?', 30.days.ago]).count
      self.settings['non_author_uses'] += conns.where(['user_id != ?', self.user_id]).count
      conns.where(home: true).group('locale').count('home').each do |lang, count|
        loc = (lang || 'en').split(/_|-/)[0]
        self.settings['locale_home_uses'][lang] = (self.settings['locale_home_uses'][lang] || 0) + count
        self.settings['locale_home_uses'][loc] = (self.settings['locale_home_uses'][loc] || 0) + count if lang != loc
      end
    else
      self.settings['home_uses'] = 0
      self.settings['recent_home_uses'] = 0
      self.settings['uses'] = 0
      self.settings['recent_uses'] = 0
      conns.each do |ubc|
        if !ubc.locale && ubc.board && ubc.board.settings
          UserBoardConnection.where(id: ubc.id).update_all(locale: ubc.board.settings['locale'])
          ubc.locale = ubc.board.settings['locale']
        end
        loc = (ubc.locale || 'en').split(/_|-/)[0]
        self.settings['home_uses'] +=1 if ubc.home
        self.settings['recent_home_uses'] += 1 if ubc.home && ubc.updated_at > 30.days.ago
        self.settings['uses'] += 1
        self.settings['recent_uses'] += 1 if ubc.updated_at > 30.days.ago
        self.settings['non_author_uses'] +=1 if ubc.user_id != self.user_id
        self.settings['locale_home_uses'][ubc.locale] = (self.settings['locale_home_uses'][ubc.locale] || 0) + 1 if ubc.home
        self.settings['locale_home_uses'][loc] = (self.settings['locale_home_uses'][loc] || 0) + 1 if ubc.home && ubc.locale != loc
      end
    end
    self.any_upstream ||= false
    if self.settings['never_edited']
      self.popularity = -1
      self.home_popularity = -1
    else
      # TODO: a real algorithm perchance?
      self.popularity = (self.starred_by?('bump') ? 50 : 0) + (self.settings['stars'] * 10) + self.settings['uses'] + (self.settings['forks']) + (self.settings['recent_uses'] * 3) + (self.settings['recent_forks'] * 3)
      self.home_popularity = (self.any_upstream ? 0 : 10) + (self.any_upstream ? 0 : self.settings['stars'] * 3) + self.settings['home_uses'] + (self.settings['home_forks']) + (self.settings['recent_home_uses'] * 5) + (self.settings['recent_home_forks'] * 5)
      if self.settings['home_board']
        self.home_popularity *= 10
        self.popularity *= 8
      end
      if self.parent_board_id
        self.popularity /= 3
        self.home_popularity /= 3
      end
      if self.settings['copy_id']
        if self.settings['copy_id'] == self.global_id
          self.popularity /= 2
          self.home_popularity /= 2
        else
          self.popularity /= 3
          self.home_popularity /= 3
        end
      end
    end
    found_locales = {}
    if self.settings['locale']
      found_locales[self.settings['locale']] = true
      if self.settings['locale'].match(/-|_/)
        found_locales[self.settings['locale'].split(/-|_/)[0]] = true
      end
    end
    locales.each do |locale|
      next unless locale
      found_locales[locale] = true
      lang = locale.split(/-|_/)[0]
      found_locales[lang] = true
      pop_score = ((self.settings['locale_stars'][locale] || 0) * 10) + (self.settings['locale_home_uses'][locale] || 0) + ((self.settings['locale_home_forks'][locale] || 0) * 2)
      home_pop_score = (self.any_upstream ? 0 : 10) + ((self.settings['locale_stars'][locale] || 0) * 3) + (self.settings['locale_home_uses'][locale] || 0) + ((self.settings['locale_home_forks'][locale] || 0) * 2)
      pops[locale] = pop_score
      home_pops[locale] = home_pop_score
      pops[lang] = [pops[lang] || 0, pop_score].max
      home_pops[lang] = [home_pops[lang] || 0, home_pop_score].max
    end
    if self.id
      if self.fully_listed?
        found_locales.each do |locale, nvmd|
          bl = BoardLocale.find_or_create_by(board_id: self.id, locale: locale)
          bl.search_string = self.search_string_for(locale)
          if self.settings['never_edited']
            bl.popularity = -1
            bl.home_popularity = -1
          else
            bl.popularity = home_pops[locale] || 0
            bl.home_popularity = pops[locale] || 0
          end
          bl.save
        end
      else
        BoardLocale.where(board_id: self.id).delete_all
      end
    end
    if (self.buttons || []).length == 0
      self.popularity = 0
      self.home_popularity = 0
    end
    true
  end

  def search_string_for(locale)
    lang = (locale || 'en').split(/-|_/)[0]
    trans =  BoardContent.load_content(self, 'translations') || {}
    board_string = ""
    name = nil
    if trans['board_name']
      name = trans['board_name'][locale] || trans['board_name'][lang]
      if !name
        other = trans['board_name'].keys.detect{|l| l.match(/^#{lang}/)}
        name = trans['board_name'][other] if other
      end
    end
    name ||= self.settings['name'] || ''
    board_string += name
    board_string += ' ' + name
    grid = BoardContent.load_content(self, 'grid')
    buttons = self.buttons
    if grid && buttons
      grid['columns'].times do |jdx|
        grid['rows'].times do |idx|
          id = grid['order'][idx] && grid['order'][idx][jdx]
          button = buttons.detect{|b| b['id'] == id } || {}
          btn_trans = ((trans || {})[id.to_s] || {})
          val = (btn_trans[locale] || {})['label'] || (btn_trans[lang] || {})['label']
          if !val
            other = btn_trans.keys.detect{|l| l.match(/^#{lang}/)}
            val = btn_trans[other]['label'] if other
          end
          val ||= button['label'] || ''
          board_string += " " + val + ","
        end
      end
    end
    board_string += " " + (self.key || '')
    board_string += ' ' + name
    board_string += " " + (self.settings['name'] || "").downcase
    board_string += " " + (self.settings['description'] || "").downcase
    board_string
  end

  def self.long_query(query, locale, board_ids)
    offset = 0
    result = []
    board_ids.each_slice(25) do |ids|
      break if result.length > 50
      boards = Board.find_all_by_global_id(ids).sort_by{|b| ids.index(b.global_id) }
      result += Board.sort_for_query(boards, query, locale, offset, board_ids.length)
      offset += 25
    end
    result = result.sort_by{|b| b.instance_variable_get('@boost')}.reverse
    JsonApi::Board.paginate({}, result, {locale: locale})
  end

  def self.sort_for_query(boards_slice, query, locale, offset, total)
    locale ||= 'any'
    boards = []
    lang = locale.split(/-|_/)[0]
    boards_slice.each_with_index do |brd, idx| 
      break if boards.length > 50
      board_string = ""
      boost = 1 - ((idx + offset).to_f / total.to_f / 2.0)
      if brd.settings['locale'] == locale
        boost += 1 
        board_string += "locale:#{locale}"
      elsif (brd.settings['locale'] || 'en').split(/-|_/)[0] == lang.split(/-|_/)[0]
        boost += 0.5 
        board_string += "locale:#{lang}"
      end
      board_string = " " + brd.search_string_for(locale == 'any' ? (brd.settings['locale'] || 'en') : locale)
      if board_string.match(/#{query}/i)
        boost *= 10 
        boards << brd
      end
      brd.instance_variable_set('@boost', boost) 
    end
    query = CGI.unescape(query || '').downcase
    res = boards.sort_by{|b| b.instance_variable_get('@boost')}.reverse
  end

  def self.sort_for_locale(boards, locale, sort, ranks)
    # When sorting by locale, apply a locale boost for a re-sort
    return boards unless locale && locale != 'any' && sort
    res = boards.sort_by do |board|
      boost = 1 * (ranks[board.id] || 0.1)
      forks = (board.settings['locale_home_forks'] || {})[locale] || (board.settings['locale_home_forks'] || {})[locale.split(/-|_/)[0]] || 0
      uses = (board.settings['locale_home_uses'] || {})[locale] || (board.settings['locale_home_uses'] || {})[locale.split(/-|_/)[0]] || 0
      stars = (board.settings['locale_stars'] || {})[locale] || (board.settings['locale_stars'] || {})[locale.split(/-|_/)[0]] || 0
      if sort == 'popularity'
        boost += 5 if board.settings['locale'] == locale
        boost += 3 if board.settings['locale'] != locale && board.settings['locale'].split(/-|_/)[0] == locale.split(/-|_/)[0]
        boost += uses / 3
        boost += forks / 5
        boost += stars
      elsif sort == 'home_popularity'
        boost += 5 if board.settings['locale'] == locale
        boost += 3 if board.settings['locale'] != locale && board.settings['locale'].split(/-|_/)[0] == locale.split(/-|_/)[0]
        boost += uses
        boost += forks / 3
        boost += stars / 2
      end
      (board.popularity || -1) * boost
    end
    res.reverse
  end

  def check_content_overrides
    BoardContent.track_differences(self, self.board_content, true) if self.board_content
    true
  end

  def edit_key
    self.settings['edit_key']
  end
  
  def find_copies_by(user)
    return [] unless self.id
    if user
      ids = [user.id] + self.class.local_ids(user.supervised_user_ids || [])
      ids = ids[0, 5] # Too many users would gum this up for sure
      # TODO: sharding
      boards = Board
      if defined?(Octopus)
        conn = (Octopus.config[Rails.env] || {}).keys.sample
        boards = Board.using(conn) if conn
      end
      boards.includes(:board_content).where(:parent_board_id => self.id, :user_id => ids).limit(15).sort_by{|b| [b.user_id == user.id ? 0 : 1, 0 - b.id] }
    else
      []
    end
  end
  
  def self.import(user_id, url)
    boards = []
    user = User.find_by_global_id(user_id)
    Progress.update_current_progress(0.05, :generating_boards)
    begin
      Progress.as_percent(0.05, 0.9) do
        boards = Converters::Utils.remote_to_boards(user, url)
      end
    rescue => e
      if e.message.match(/protected boards/)
        return {error: {message: "protected material cannot be imported", protected: true}}
      else
        raise e
      end
    end
    boards.each do |board|
      board.settings['copy_id'] = boards[0].global_id
      board.save
    end
    return boards.map{|b| JsonApi::Board.as_json(b, :permissions => user) }
  end
  
  def generate_download(user_id, type, opts)
    res = {}
    user = User.find_by_global_id(user_id)
    Progress.update_current_progress(0.03, :generating_files)
    grid = BoardContent.load_content(self, 'grid') || {}
    cells = (grid['rows'] || 3) * (grid['columns'] || 4)
    approx_cells = cells * ((self.settings['downstream_board_ids'] || []).length + 1)
    Progress.update_minutes_estimate(approx_cells * 0.09 / 60)
    Progress.as_percent(0.03, 0.9) do
      if ['obz', 'obf', 'pdf'].include?(type.to_s)
        url = Converters::Utils.board_to_remote(self, user, {
          'file_type' => type.to_s,
          'include' => opts['include'] || 'this',
          'headerless' => !!opts['headerless'],
          'text_on_top' => !!opts['text_on_top'],
          'transparent_background' => !!opts['transparent_background'],
          'symbol_background' => opts['symbol_background'],
          'text_only' => !!opts['text_only'],
          'text_case' => opts['text_case'],
          'font' => opts['font']
        })
        if !url
          raise Progress::ProgressError, "No URL generated"
        end
        res = {:download_url => Uploader.fronted_url(url)}
      else
        raise Progress::ProgressError, "Unexpected download type, #{type}"
      end
    end
    return res
  end

  def generate_possible_clone
    if @sub_id
      copy_id = self.settings['copy_id'] || self.global_id.split(/-/)[0]
      self.copy_for(@sub_global, {copy_id: copy_id, skip_save: true})
    else
      return self
    end
  end
  
  def generate_defaults
    raise "cannot save a shallow clone" if @sub_id
    self.settings ||= {}
    self.settings['name'] ||= "Unnamed Board"
    self.settings['edit_key'] = Time.now.to_f.to_s + "-" + rand(9999).to_s
    self.settings['image_url'] = nil if self.settings['image_url'] && self.settings['image_url'].match(/^data/)
    if !self.settings['image_url']
      self.settings['image_url'] = DEFAULT_ICON
      self.settings['default_image_url'] = DEFAULT_ICON
    elsif self.settings['image_url'] != self.settings['default_image_url']
      self.settings['default_image_url'] = nil
    end
    @brand_new = !self.id
    @buttons_changed = true if self.buttons && !self.id
    buttons = self.buttons || []
    @button_links_changed = true if buttons.any?{|b| b['load_board'] } && !self.id
    self.settings['total_buttons'] = buttons.length + (self.settings['total_downstream_buttons'] || 0)
    self.settings['unlinked_buttons'] = buttons.select{|btn| !btn['load_board'] }.length + (self.settings['unlinked_downstream_buttons'] || 0)

    if @buttons_changed.is_a?(String)
      @edit_description ||= {
        'timestamp' => Time.now.to_f,
        'notes' => [@buttons_changed]
      }
    end
    if @edit_description
      if self.settings['edit_description'] && self.settings['edit_description']['timestamp'] < @edit_description['timestamp'] - 1
        @edit_description = nil
      end
    end
    self.settings['edit_description'] = @edit_description
    @edit_description = nil

    self.settings['buttons'] ||= []
    self.buttons.each do |button|
      if button['load_board'] && button['load_board']['id'] && button['load_board']['id'] == self.related_global_id(self.parent_board_id) && @update_self_references == nil && !self.settings['self_references_updated']
        @update_self_references = true
      end
    end
    self.any_upstream = self.settings && self.settings['immediately_upstream_board_ids'] && self.settings['immediately_upstream_board_ids'].length > 0
    self.any_upstream ||= false
    grid = BoardContent.load_content(self, 'grid')
    grid ||= {}
    grid['rows'] = (grid['rows'] || 2).to_i
    grid['columns'] = (grid['columns'] || 4).to_i
    grid['order'] ||= []
    grid['rows'].times do |i|
      grid['order'][i] ||= []
      grid['columns'].times do |j|
        grid['order'][i][j] ||= nil
      end
      if grid['order'][i].length > grid['columns']
        grid['order'][i] = grid['order'][i].slice(0, grid['columns'])
      end
    end
    if grid['order'].length > grid['rows']
      grid['order'] = grid['order'].slice(0, grid['rows'])
    end
    if grid['labels'] && self.buttons.length == 0
      self.populate_buttons_from_labels(grid.delete('labels'), grid.delete('labels_order'))
    end
    self.settings['grid'] = grid
    update_immediately_downstream_board_ids
    # Clip huge downstream lists
    self.settings['downstream_board_ids'] = self.settings['downstream_board_ids'][0, 500] if self.settings['downstream_board_ids']
    
    translations = (BoardContent.load_content(self, 'translations') || {})
    data_hash = Digest::MD5.hexdigest(self.global_id.to_s + "_" + grid.to_json + "_" + self.buttons.to_json + "_" + self.public.to_s + "_" + self.settings['unlisted'].to_s + "_" + translations.to_json)
    self.settings['revision_hashes'] ||= []
    if !self.settings['revision_hashes'].last || self.settings['revision_hashes'].last[0] != data_hash
      @track_revision = [data_hash, Time.now.to_i]
      self.settings['revision_hashes'] << @track_revision
      self.current_revision = data_hash
    end
    self.settings['revision_hashes'] = self.settings['revision_hashes'].slice(-3, 3) if self.settings['revision_hashes'].length > 3

    if @map_later
      self.settings['images_not_mapped'] = true
    end
    
    self.settings['license'] ||= {type: 'private'}
    # self.name = self.settings['name']
    if self.unshareable?
      self.public = false unless self.settings['protected'] && self.settings['protected']['demo'] && !self.parent_board_id
    elsif self.public == nil
      if self.user && self.user.any_premium_or_grace_period?(true)
        self.public = false
      else
        self.public = true
      end
    end
    if self.settings['protected'] && self.settings['protected']['vocabulary'] && !self.parent_board_id
      self.settings['protected']['vocabulary_owner_id'] ||= self.user.global_id
    end
    if self.settings['name'] && self.settings['name'].match(/LAMP|WFL/)
      self.public = false
    end
    UserLink.invalidate_cache_for(self)
          
    self.settings['locale'] ||= 'en'
    langs = []
    translations.each do |k, trans|
      if trans.is_a?(Hash)
        langs += trans.keys
      end
    end
    langs.uniq!
    self.settings['locales'] = ([self.settings['locale']] + langs).uniq
    self.settings.delete('search_string')
    self.search_string = self.settings['locales'].map{|s| "locale:#{s}" }.join(" ")
    self.search_string += " root" if !self.settings['copy_id'] || (self.id && self.settings['copy_id'] == self.global_id)
    # self.settings['search_string'] = "#{self.settings['name']} locale:#{self.settings['locale'] || ''}".downcase
    # langs.each do |loc, txt|
    #   self.settings['search_string'] += "locale:#{loc}"
    # end
    # locs = {}
    # (BoardContent.load_content(board, 'translations') || {}).each do |attr, hash|
    #   if hash.is_a?(Hash)
    #     hash.each do |loc, vals|
    #       locs[loc] ||= ""
    #       if attr == 'board_name'
    #         locs[loc] += " #{vals}"
    #       elsif vals.is_a?(Hash) && vals['label']
    #         locs[loc] += " #{vals['label']}"
    #       end
    #     end
    #   end
    # end
    # self.settings['search_string'] += " #{self.key} #{self.labels} #{self.settings['description'] || ""}".downcase
    # search_string is limited to 4096
    # self.search_string = self.fully_listed? ? (self.settings['search_string'] || '')[0, 4096] : nil
    self.generate_stats unless self.settings['stars']

    true
  end
  
  def fully_listed?
    self.public && (!self.settings || !self.settings['unlisted'])
  end

  def unshareable?
    if self.settings && self.settings['protected']
      return true if self.settings['protected']['vocabulary']
    end
    false
  end

  def copyable_if_authorized?(user)
    return true if self.settings && self.settings['protected'] && user && self.settings['protected']['vocabulary_owner_id'] == user.global_id
    if !(self.settings['protected'] || {})['vocabulary_owner_id']
      return false if self.parent_board && self.parent_board.unshareable?
      return true if user && user.id == self.user_id
    end
    return !self.unshareable?
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
    grid = BoardContent.load_content(self, 'grid')
    buttons = self.buttons
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
    res = self.settings['full_set_revision'] || self.current_revision || self.global_id
    if @sub_global
      ue = @sub_global.user_extra
      ids = self.settings['downstream_board_ids'] || []
      other_ids = []
      if ue && ue.settings['replaced_boards']
        ids.each do |id|
          new_id = ue.settings['replaced_boards'][id]
          other_ids << new_id if new_id
        end
      end
      if other_ids.length > 0
        revisions = Board.find_all_by_global_id(other_ids).map{|b| b.current_revision }
        res = Digest::MD5.hexdigest(res + revisions.join(','))[0, 10]
      end
    end
    res
  end
  
  def populate_buttons_from_labels(labels, labels_order)
    labels_order ||= 'columns'
    max_id = self.buttons.map{|b| b['id'].to_i || 0 }.max || 0
    idx = 0
    buttons = self.buttons
    grid = BoardContent.load_content(self, 'grid')
    labels.split(/\n|,\s*/).each do |label|
      label.strip!
      next if label.blank?
      max_id += 1
      button = {
        'id' => max_id,
        'label' => label,
        'suggest_symbol' => true
      }
      buttons << button
      @buttons_changed = 'populated_from_labels'

      row = idx % grid['rows']
      col = (idx - row) / grid['rows']
      if labels_order == 'rows'
        col = idx % grid['columns']
        row = (idx - col) / grid['columns']
      end  

      if row < grid['rows'] && col < grid['columns']
        grid['order'][row][col] = button['id']
      end
      idx += 1
    end
    self.settings['grid'] = grid
    self.settings['buttons'] = buttons
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

  def route_to(board_id)
    root = self
    visited = []
    to_check = [root.global_id]
    ups = {}
    while to_check.length > 0
      ref = Board.find_by_path(to_check.shift)
      if ref
        puts "#{ref.key} #{to_check.length} #{visited.length}"
        visited << ref.global_id
        if (ref.settings['downstream_board_ids'] || []).include?(board_id)
          puts "maybe... #{ref.key}"
          if (ref.settings['immediately_downstream_board_ids'] || []).include?(board_id)
            puts "found it!"
            puts ref.key
            ref_id = ref.global_id
            done_ups = {}
            while ups[ref_id] && !done_ups[ref_id]
              ref_id = ups[ref_id][1]
              done_ups[ref_id] = true
              puts ups[ref_id][0]
            end
            to_check = []
          else
            to_check += (ref.settings['downstream_board_ids']) - visited
          end
          ref.settings['immediately_downstream_board_ids'].each do |id|
            ups[id] ||= [ref.key, ref.global_id]
          end
        end
      end
    end
    puts "done"
  end
  
  def post_process
    if @skip_post_process
      @skip_post_process = false
      return
    end
    
    rev = (((self.settings || {})['revision_hashes'] || [])[-2] || [])[0] || current_revision
    notify('board_buttons_changed', {'revision' => rev, 'reason' => @buttons_changed}) if @buttons_changed && !@brand_new
    content_changed = @button_links_changed || @brand_new || @buttons_changed
    self.map_images # NOTE: this clears @buttons_changed
    
    if self.settings && self.settings['image_url'] == DEFAULT_ICON && self.settings['default_image_url'] == self.settings['image_url'] && self.settings['name'] && self.settings['name'] != 'Unnamed Board'
      self.schedule(:check_image_url)
    end
    
    if @update_self_references
      self.update_self_references
    end
    
    if @check_for_parts_of_speech
      self.schedule(:check_for_parts_of_speech_and_inflections)
      @check_for_parts_of_speech = nil
    end

    if self.settings && self.settings['undeleted'] && (self.settings['image_urls'] || self.settings['sound_urls'])
      self.schedule(:restore_urls)
    end
    if !@skip_board_post_checks
      schedule(:update_affected_users, @brand_new) if content_changed
      schedule(:current_library, true) if content_changed && !self.settings['common_library'] && !self.settings['swapped_library']
    end
    @skip_board_post_checks = false

    schedule_downstream_checks(Board.last_scheduled_stamp)
  end

  def assert_shallow_mapping
    if @shallow_source_changed && (self.settings && self.settings['shallow_source']) && self.user
      ue = UserExtra.find_or_create_by(user: self.user)
      ue.settings['replaced_boards'] ||= {}
      ue.settings['replaced_boards'][self.settings['shallow_source']['id'].split(/-/)[0]] = self.global_id(true)
      ue.settings['replaced_boards'][self.settings['shallow_source']['key'].split(/my:/)[1].sub(/:/, '/')] = self.global_id(true)
      root = self.root_board
      if root && root != self
        ue.settings['replaced_roots'] ||= {}
        ue.settings['replaced_roots'][root.global_id(true)] = {
          'id' => root.shallow_id, 
          'key' => root.shallow_key
        }
      end
      ue.save
    end
  end

  def check_inflections
    # this used to be a background job, but I think it needs to be part of the original save now
    if @check_for_parts_of_speech
      self.check_for_parts_of_speech_and_inflections(false)
      @check_for_parts_of_speech = nil
    end
  end

  def restore_urls
    (self.settings['image_urls'] || {}).each do |id, url|
      bi = ButtonImage.find_by_global_id(id)
      if !bi
        bi = ButtonImage.new
        hash = Board.id_pieces(id)
        @buttons_changed = true
        parts = id.split(/_/)
        bi.id = hash[:id]
        bi.nonce = hash[:nonce]
        bi.user_id = self.user_id
        bi.board_id = self.id
        bi.settings = {'avatar' => false, 'badge' => false, 'protected' => false, 'pending' => false}
        bi.url = url
        bi.save
      end
    end
    (self.settings['sound_urls'] || {}).each do |id, url|
      bs = ButtonSound.find_by_global_id(id)
      if !bs
        bs = ButtonSound.new
        hash = Board.id_pieces(id)
        @buttons_changed = true
        parts = id.split(/_/)
        bs.id = hash[:id]
        bs.nonce = hash[:nonce]
        bs.user_id = self.user_id
        bs.settings = {'protected' => false, 'pending' => false}
        bs.url = url
        bs.save
      end
    end
    self.settings.delete('undeleted')
    self.settings.delete('image_urls')
    self.settings.delete('sound_urls')
    @buttons_changed = true
    self.save
  end
  
  def update_self_references
    @update_self_references = false
    return if @sub_id
    buttons = self.buttons || []
    self.using(:master).reload
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
    # update user.sync_stamp based on UserBoardConnection 
    # (including supervisors of connected users)
    # TODO: sharding
    board_ids = [self.global_id]
    if is_new_board
      board_ids += (self.settings['immediately_upstream_board_ids'] || [])
    end
    # TODO: sharding
    ubcs = UserBoardConnection.where(:board_id => Board.local_ids(board_ids))
    root_users = ubcs.map(&:user).uniq.compact
    more_user_ids = root_users.map(&:supervisor_user_ids).flatten.uniq
    user_ids = root_users.map(&:global_id) + more_user_ids
    
    # TODO: sharding
    users = User.where(:id => User.local_ids(user_ids))
    users.find_in_batches(batch_size: 20) do |batch|
      batch.each{|user| user.save_with_sync('boards_changed') }
    end
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
      locale = (self.settings['locale'] || 'en').split(/-|_/)[0].downcase
      res = Typhoeus.get("https://www.opensymbols.org/api/v1/symbols/search?q=#{CGI.escape(self.settings['name'])}&locale=#{locale}", :timeout => 5, :ssl_verifypeer => false)
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
  
  def map_images(force=false)
    return unless @buttons_changed || force
    if @map_later && !force
      self.schedule(:map_images, true)
      return
    end
    @buttons_changed = false
    @button_links_changed = false

    images = []
    sounds = []
    (self.grid_buttons || []).each do |button|
      images << {:id => button['image_id'], :label => button['label']} if button['image_id']
      sounds << {:id => button['sound_id']} if button['sound_id']
    end
    image_ids = images.map{|i| i[:id] }
    image_ids_hash = Digest::MD5.hexdigest(image_ids.length.to_s + image_ids.join(','))[0, 8]

    # found_images = BoardButtonImage.images_for_board(self.id)
    # existing_image_ids = found_images.map(&:global_id)
    # existing_images = existing_image_ids.map{|id| {:id => id} }
    # new_images = images.select{|i| !existing_image_ids.include?(i[:id]) }
    # orphan_images = existing_images.select{|i| !image_ids.include?(i[:id]) }
    # BoardButtonImage.connect(self.id, new_images, :user_id => self.user.global_id)
    # BoardButtonImage.disconnect(self.id, orphan_images)

    found_sounds = BoardButtonSound.sounds_for_board(self.id)
    existing_sound_ids = found_sounds.map(&:global_id)
    existing_sounds = existing_sound_ids.map{|id| {:id => id} }
    sound_ids = sounds.map{|i| i[:id] }
    new_sounds = sounds.select{|i| !existing_sound_ids.include?(i[:id]) }
    orphan_sounds = existing_sounds.select{|i| !sound_ids.include?(i[:id]) }
    BoardButtonSound.connect(self.id, new_sounds, :user_id => self.user.global_id)
    BoardButtonSound.disconnect(self.id, orphan_sounds)
    
    if image_ids_hash != self.settings['image_ids_hash'] || new_sounds.length > 0 || orphan_sounds.length > 0
      if image_ids_hash != self.settings['image_ids_hash']
        self.schedule(:update_setting, {'image_ids_hash' => image_ids_hash}, nil, :save_without_post_processing)
      end
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
        prot = self.settings['protected'] || {}
        prot['media'] = true
        prot['media_sources'] = sources
        self.update_setting({
          'protected' => prot
        }, nil, :save_without_post_processing)
      elsif (protected_images + protected_sounds).length == 0 && self.settings['protected'] && self.settings['protected']['media'] == true
        # TODO: race condition?
        if self.settings['protected']
          prot = self.settings['protected']
          prot['media'] = false
          prot['media_sources'] = []
          self.update_setting({
            'protected' => prot
          }, nil, :save_without_post_processing)
        end
      end
    end
    @images_mapped_at = Time.now.to_i
  end
  
  def require_key
    self.key ||= generate_board_key(self.settings && self.settings['name'])
    true
  end
  
  def cached_user_name
    (self.key || "").split(/\//)[0]
  end

  def buttons
    res = BoardContent.load_content(self, 'buttons')
    if @sub_id && @sub_global
      res.each do |button|
        if button['load_board']
          if button['load_board']['id']
            orig = button['load_board']['id'].split(/-/)[0]
            button['load_board']['id'] = "#{orig}-#{@sub_global.global_id}"
          end
          if button['load_board']['key']
            orig = button['load_board']['key']
            if orig.match(/\/my:/)
              orig = orig.split(/\/my:/)[1].sub(/:/, '/')
            end
            button['load_board']['key'] = "#{@sub_global.user_name}/my:#{orig.sub(/\//, ':')}"
          end
        end
      end
    end
    res
  end

  def grid_buttons
    grid = BoardContent.load_content(self, 'grid')
    ids = nil
    if grid && grid['order']
      grid['order'].flatten.compact.uniq.each{|id| ids ||= {}; ids[id.to_s] = true }
    end
    res = self.buttons
    if ids != nil
      res = res.select{|b| ids[b['id'].to_s] }
    end
    res || []
  end

  def self.vocab_name(board)
    return nil unless board
    if board.key.match(/\/core-\d/)
      'Quick Core'
    elsif board.key.match(/vocal-flair/)
      'Vocal Flair'
    elsif board.key.match(/sequoia/)
      'Sequoia'
    else
      str = board.key.split(/\//)[1].sub(/_\d+$/, '')
      str.instance_variable_set('@board_key', true)
      str
    end
  end
  
  def process_params(params, non_user_params)
    raise "user required as board author" unless self.user_id || non_user_params[:user]
    @edit_notes = []
    self.user ||= non_user_params[:user] if non_user_params[:user]
    
    self.settings ||= {}
    ref_user = non_user_params[:author] || non_user_params[:user] || self.user
    if !params['parent_board_id'].blank? && !self.parent_board_id
      parent_board = Board.find_by_global_id(params['parent_board_id'])
      if !parent_board
        add_processing_error('parent board not found')
        return false
      elsif parent_board.unshareable? && !non_user_params[:allow_copying_protected_boards]
        add_processing_error('cannot copy protected boards')
        return false
      end
      if self.parent_board_id != parent_board.id
        self.parent_board = parent_board
        @shallow_source_changed = true
        self.settings['shallow_source'] = nil
        if parent_board.instance_variable_get('@sub_id')
          self.settings['shallow_source'] = {
            'key' => parent_board.key,
            'id' => parent_board.global_id
          }
        end
        if parent_board.settings['protected']
          self.settings['protected'] = (self.settings['protected'] || {}).merge(parent_board.settings['protected'])
          if params['new_owner'] && self.settings['protected']['vocabulary'] && !self.settings['protected']['sub_owner']
            if parent_board.allows?(ref_user, 'edit') && parent_board.copyable_if_authorized?(ref_user)
              self.settings['protected']['vocabulary_owner_id'] = self.user.global_id
              self.settings['protected']['sub_owner'] = parent_board.settings['protected']['sub_owner'] || parent_board.user != self.user
              self.settings['protected']['sub_owner'] = false if params['disconnect']
            else
              self.settings['protected']['sub_owner'] = true
            end
          end
        end
        self.settings['source_board_id'] = parent_board.source_board.global_id
        BoardContent.apply_clone(parent_board, self)
      end
    end
    if params['disconnect'] && self.parent_board
      if self.parent_board.allows?(ref_user, 'edit')
        self.settings['copy_parent_board_id'] = self.parent_board.global_id
        self.parent_board_id = nil
      end
    end
    self.settings['last_updated'] = Time.now.iso8601

    old_name = nil
    if params['locale']
      if self.settings['locale'] != params['locale'] && self.settings['locale'] && self.settings['name']
        old_name = {locale: self.settings['locale'], name: self.settings['name']}
      end
      self.settings['locale'] = params['locale'] 
    end
    if params['copy_key'] && !@sub_id
      b = Board.find_by_path(params['copy_key'])
      if b && b.user_id == self.user_id && b.global_id != self.settings['copy_id'] && b.global_id != self.global_id
        # Set copy_id to the same value for all downstream boards that had this board as the copy_id
        self.settings['copy_id'] = b.global_id
        @shallow_source_changed = true
        subs = Board.find_all_by_global_id(self.settings['downstream_board_ids'] || [])
        copy_subs = subs.select{|b| b.user_id == self.user_id && b.settings['copy_id'] == self.global_id }
        copy_subs.each{|brd| brd.settings['copy_id'] = b.global_id; brd.save_subtly }
      elsif params['copy_key'].blank?
        self.settings.delete('copy_id')
      end
    end
    if !self.id && params['source_id']
      # check if the user has edit permission on the source, and only set this if so
      ref_board = Board.find_by_global_id(params['source_id'])
      if ref_board && ref_board.allows?(non_user_params[:user], 'edit')
        self.settings['copy_id'] ||= ref_board.settings['copy_id'] || ref_board.global_id
        @shallow_source_changed = true
        self.settings['locale'] ||= ref_board.settings['locale']
      end
    end
    if !self.id && params['parent_board_id']
      self.settings['never_edited'] = true
    end

    @edit_notes << "renamed the board" if params['name'] && self.settings['name'] != params['name']
    self.settings['name'] = process_string(params['name']) if params['name']
    self.settings['prefix'] = process_string(params['prefix']) if params['prefix']
    self.settings.delete('prefix') if self.settings['prefix'].blank?
    self.settings['word_suggestions'] = params['word_suggestions'] if params['word_suggestions'] != nil
    @edit_notes << "updated the description" if params['description'] && params['description'] != self.settings['description']
    self.settings['description'] = process_string(params['description']) if params['description']
    @edit_notes << "changed the image" if params['image_url'] && params['image_url'] != self.settings['image_url']
    self.settings['image_url'] = params['image_url'] if params['image_url']
    @edit_notes << "changed the background" if params['background'] && params['background'].to_json != self.settings['background'].to_json
    self.settings['background'] = BoardContent.load_content(self, 'background')
    self.settings['background'] = params['background'] if params['background']
    if self.settings['background']
      self.settings['background']['delay_prompts'] ||= self.settings['background']['delayed_prompts'] if self.settings['background']['delayed_prompts']
      self.settings['background']['image'] ||= self.settings['background']['image_url'] if self.settings['background']['image_url']
      self.settings['background']['prompt'] ||= self.settings['background']['prompt_text'] if self.settings['background']['prompt_text']
    end

    if params['intro']
      self.settings['intro'] = params['intro'] 
      # When a board is copied and buttons change, the intro
      # should be marked unapproved until the user has manually
      # reviewed it.
      self.settings['intro']['unapproved'] = true if self.settings['never_edited'] && self.settings['intro'] && self.parent_board_id && params['intro']['unapproved'] != false
      self.settings['intro'].delete('unapproved') unless self.settings['intro']['unapproved']
    end
    self.settings['home_board'] = params['home_board'] if params['home_board'] != nil
    self.settings['categories'] = params['categories'] if params['categories']
    self.settings['hide_empty'] = params['hide_empty'] if params['hide_empty'] != nil
    self.settings['text_only'] = params['text_only'] if params['text_only'] != nil
    self.settings['dim_header'] = params['dim_header'] if params['dim_header'] != nil
    self.settings['small_header'] = params['small_header'] if params['small_header'] != nil
    self.settings['never_edited'] = false if self.id
    button_params = params['buttons']
    button_params.instance_variable_set('@add_voc_error', non_user_params['add_voc_error']) if button_params
    process_buttons(params['buttons'], non_user_params[:user], non_user_params[:author], params['translations']) if params['buttons']
    prior_license = self.settings['license'].to_json
    process_license(params['license']) if params['license']
    @edit_notes << "changed the license" if self.settings['license'].to_json != prior_license

    if params['translations']
      self.settings['translations'] = BoardContent.load_content(self, 'translations') || {}
      self.settings['translations']['default'] = params['translations']['default']
      self.settings['translations']['current_label'] = params['locale'] || params['translations']['current_label']
      self.settings['translations']['current_vocalization'] = params['locale'] || params['translations']['current_vocalization']
      self.settings['translations']['board_name'] = params['translations']['board_name']
      if self.settings['name'] && params['locale']
        self.settings['translations']['board_name'] ||= {}
        self.settings['translations']['board_name'][params['locale']] = self.settings['name']
        if old_name && !old_name[:locale].blank? && !old_name[:name].blank?
          self.settings['translations']['board_name'][old_name[:locale]] ||= old_name[:name]
          if old_name[:name] == self.settings['name']
            any_old_locale = false
            self.settings['translations'].each do |k, hash|
              any_old_locale = true if k != 'board_name' &&  hash.is_a?(Hash) && hash[old_name[:locale]]
            end
            self.settings['translations']['board_name'].delete(old_name[:locale]) if !any_old_locale
          end
        end
      end
    end
    self.star(non_user_params[:updater], params['starred']) if params['starred'] != nil
    
    self.settings['grid'] = params['grid'] if params['grid']
    if params['visibility'] != nil && !self.unshareable?
      if params['update_visibility_downstream']
        self.schedule_for(:priority, :update_privacy, params['visibility'], (non_user_params[:updater] || ref_user).global_id, [])
      end
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
    elsif params['public'] != nil && !self.unshareable?
#       if self.public != false && params['public'] == false && (!self.user || !self.user.any_premium_or_grace_period?)
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

    if self.copyable_if_authorized?(ref_user)
      if (self.settings['categories'] || []).include?('protected_vocabulary')
        self.settings['protected'] ||= {}
        if !self.settings['protected']['vocabulary']
          self.settings['protected']['vocabulary'] = true
          self.settings['protected']['vocabulary_owner_id'] = self.user.global_id
          self.settings['protected'].delete('sub_owner')
        end
      elsif self.public || (self.settings['categories'] || []).include?('unprotected_vocabulary')
        self.settings['protected'] ||= {}
        if (self.parent_board && self.parent_board.unshareable?) || self.settings['protected']['sub_owner']
          # Copies cannot un-protect themselves
        else
          self.settings['protected'].delete('vocabulary')
          self.settings['protected'].delete('vocabulary_owner_id')
          self.settings['protected'].delete('sub_owner')
        end
      end
    end
    if self.settings['categories']
      self.settings['categories'] -= ['protected_vocabulary', 'unprotected_vocabulary']
    end

    if !params['sharing_key'].blank?
      updater = non_user_params[:updater] || non_user_params[:author]
      return false unless self.process_share(params['sharing_key'], updater && updater.global_id)
    end
    non_user_params[:key] = nil if non_user_params[:key].blank?
    if non_user_params[:key]
      non_user_params[:key].sub!(/^tmp\//, '')
      non_user_params[:key] = nil if non_user_params[:key].match(/^tmp_/)
      self.key = generate_board_key(non_user_params[:key]) if non_user_params[:key]
    end

    if self.settings['undeleted']
      self.settings['image_urls'] = params['image_urls']
      self.settings['sound_urls'] = params['sound_urls']
    end
    if self.id && @edit_notes.length > 0
      @edit_description = {
        'timestamp' => Time.now.to_f,
        'notes' => @edit_notes
      }
    end
    true
  end
  
  def categories
    res = (self.settings['categories'] || [])
    res << 'layout' if self.settings['layout_category']
    res << 'layouts' if self.settings['layout_category'] || self.settings['secondary_layout_category']
    res
  end
    
  def check_for_parts_of_speech_and_inflections(do_save=true)
    if self.buttons
      any_changed = false
      trans = BoardContent.load_content(self, 'translations') || {}
      buttons = self.buttons
      (self.settings['locales'] || [self.settings['locale']]).each do |loc|
        words_to_check = self.buttons.map{|b|
          btn = (trans[b['id'].to_s] || {})[loc] || b
          already_updated = btn['inflection_defaults'] && btn['inflection_defaults']['v'] == WordData::INFLECTIONS_VERSION
          already_updated = false if do_save == 'force'
          already_updated ? nil : (btn['vocalization'] || btn['label'])
        }.compact
        inflections = WordData.inflection_locations_for(words_to_check, loc)
        buttons = buttons.map do |button|
          if loc == self.settings['locale'] || !self.settings['locale']
            # look for part of speech when loading the default locale
            word = button['vocalization'] || button['label']
            if word && !button['part_of_speech']
              types = (inflections[word] || {})['types']
              types ||= (WordData.find_word(word) || {})['types'] || []
              if types && types.length > 0
                button['part_of_speech'] = types[0]
                button['suggested_part_of_speech'] = types[0]
                any_changed = true
              end
            elsif button['part_of_speech'] && button['part_of_speech'] == button['suggested_part_of_speech']
              types = (inflections[word] || {})['types']
              # if we've changed our assumption of the default, and the user hasn't updated
              # from what the system suggested, go ahead and update for them
              if types && types.length > 0 && types[0] != button['part_of_speech']
                button['part_of_speech'] = types[0]
                button['suggested_part_of_speech'] = types[0]
                any_changed = true
              end
            elsif button['part_of_speech'] && button['suggested_part_of_speech'] && button['part_of_speech'] != button['suggested_part_of_speech']
              str = "#{word}-#{button['part_of_speech']}"
              button['original_part_of_speech'] = button['suggested_part_of_speech']
              button.delete('suggested_part_of_speech')
              RedisInit.default.hincrby('overridden_parts_of_speech', str, 1) if RedisInit.default
            end
            # If there are any overrides compared to the javascript defaults,
            # persist them to the button object
            if word && inflections[word] && inflections[word]['v']
              button['inflection_defaults'] = {}.merge(inflections[word])
              any_changed = true
            end
          end
          btn = (trans[button['id'].to_s] || {})[loc]
          if btn && inflections[btn['vocalization'] || btn['label']] && inflections[btn['vocalization'] || btn['label']]['v']
            trans[button['id'].to_s][loc]['inflection_defaults'] = inflections[btn['vocalization'] || btn['label']]
            any_changed = true
          end
          button
        end
      end
      if any_changed
        self.settings['buttons'] = buttons 
        self.settings['translations'] = trans 
      end
      if any_changed && do_save
        self.assert_current_record!
        self.save 
      end
    end
  rescue ActiveRecord::StaleObjectError
    self.schedule_once(:check_for_parts_of_speech_and_inflections, do_save)
  end
  
  def process_button(button)
    raise "can't update button for a shallow clone" if @sub_id
    buttons = self.buttons
    found_button = buttons.detect{|b| b['id'].to_s == button['id'].to_s }
    if button['sound_id']
      found_button['sound_id'] = button['sound_id']
      @buttons_changed = 'button updated in-place'
    end
    self.settings['buttons'] = buttons
#    self.schedule_once(:update_button_sets)
    self.save!
  end
  
  def update_button_sets
    upstreams = [self]
    visited_ids = []
    while upstreams.length > 0
      board = upstreams.shift
#      BoardDownstreamButtonSet.schedule_once(:update_for, board.global_id)
      visited_ids << board.global_id
      ups = Board.find_all_by_global_id(board.settings['immediately_upstream_board_ids'])
      ups.each do |up|
        if !visited_ids.include?(up.global_id)
          upstreams.push(up)
        end
      end
    end
  end
  
  def process_buttons(buttons, editor, secondary_editor=nil, translations=nil)
    raise "can't update buttons for a shallow clone" if @sub_id
    add_voc_error = buttons.instance_variable_get('@add_voc_error')
    translations ||= {}
    clear_cached("images_and_sounds_with_fallbacks")
    @edit_notes ||= []
    @check_for_parts_of_speech = true
    prior_buttons = self.buttons || []
    approved_link_ids = []
    new_link_ids = []
    prior_buttons.each do |button|
      if button['load_board']
        approved_link_ids << button['load_board']['id']
        approved_link_ids << button['load_board']['key']
      end
    end
    self.settings['buttons'] = buttons.map do |button|
      if add_voc_error && button['add_vocalization'] == false && !button['load_board']
        button.delete('add_vocalization')
      end
      trans = button['translations'] || translations[button['id']] || translations[button['id'].to_s] || (BoardContent.load_content(self, 'translations') || {})[button['id'].to_s]
      button = button.slice('id', 'hidden', 'link_disabled', 'image_id', 'sound_id', 'label', 'vocalization', 
            'background_color', 'border_color', 'load_board', 'hide_label', 'url', 'apps', 'text_only', 
            'integration', 'video', 'book', 'part_of_speech', 'suggested_part_of_speech', 'external_id', 
            'painted_part_of_speech', 'home_lock', 'meta_home', 'blocking_speech', 
            'level_modifications', 'inflections', 'ref_id', 'rules', 'add_vocalization', 'no_skin');
      button.delete('meta_home') if !button['meta_home']
      button.delete('level_modifications') if button['level_modifications'] && !button['level_modifications'].is_a?(Hash)
      button.delete('ref_id') if button['ref_id'].blank?
      button.delete('rules') if button['rules'].blank?
      button['rules'] = button['rules'].compact.select{|r| r.is_a?(Array) } if button['rules']
      if button['level_modifications'] && button['level_modifications']['override']
        button['level_modifications']['override'].each do |attr, val|
          button[attr] = val
        end
      end
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
        self.settings['translations'] = BoardContent.load_content(self, 'translations') || {}
        has_trans_inflections = false
        trans.each do |loc, tran|
          if loc.is_a?(Hash)
            tran = loc
            loc = loc['locale']
          end
          next unless tran
          if loc == self.settings['locale']
            orig_button = (self.buttons || []).find{|b| b['id'] == button['id'] }
            # button settings overwrite translation settings for the default locale
            ['label', 'vocalization', 'inflections'].each do |k|
              if !orig_button || orig_button[k] != button[k]
                tran[k] = button[k] if button[k]
                tran.delete(k) if !button[k] && k != 'inflections'
              end
            end
          end
          # If inflections are set on translations AND the button, 
          # then there is a conflict, so remove it on the button
          has_trans_inflections = true if tran['inflections']

          loc = tran['locale'] || loc
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][loc] ||= {}
          self.settings['translations'][button['id'].to_s][loc]['label'] = tran['label'].to_s if tran['label']
          self.settings['translations'][button['id'].to_s][loc]['vocalization'] = tran['vocalization'].to_s if tran['vocalization'] || tran['label']
          self.settings['translations'][button['id'].to_s][loc].delete('vocalization') if self.settings['translations'][button['id'].to_s][loc]['vocalization'] == ""
          tran['inflections'].to_a.each_with_index do |str, idx|
            self.settings['translations'][button['id'].to_s][loc]['inflections'] ||= []
            self.settings['translations'][button['id'].to_s][loc]['inflections'][idx] = str.to_s if str
          end
          if tran['rules'] && tran['rules'].length > 0
            self.settings['translations'][button['id'].to_s][loc]['rules'] = tran['rules'].compact.select{|r| r.is_a?(Array) }
          else
            self.settings['translations'][button['id'].to_s][loc].delete('rules')
          end
          # ignore inflection_defaults, those should get re-added on their own
        end
        button.delete('inflections') if has_trans_inflections
      end
      if button['part_of_speech'] && button['part_of_speech'] == ''
        button.delete('part_of_speech')
      end
      if !button['load_board'] && !button['apps'] && !button['url'] && !button['video']
        button.delete('link_disabled')
      end
      button
    end

    if self.buttons.to_json != prior_buttons.to_json
      @edit_notes << "modified buttons"
      @buttons_changed = 'buttons processed' 
      @button_links_changed = true if new_link_ids.length > 0
    end
    self.buttons
  end
  
  def icon_url_or_fallback
    fallback = DEFAULT_ICON
    self.settings['image_url'].blank? ? fallback : self.settings['image_url']
  end
  
  def rollback_board_set(date)
    boards = [self]
    raise "can't rollback shallow clone" if @sub_id
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
    ue = self.user && self.user.user_extra
    if ue && ue.settings['replaced_boards']
      id = self.global_id(true)
      changed = false
      ue.settings['replaced_boards'].each do |key, val|
        if val == id
          ue.settings['replaced_boards'].delete(key) 
          changed = true
        end
      end
      ue.save if changed
    end
    DeletedBoard.process(self)
  end
  
  def images_and_sounds_for(user)
    # TODO: this is silly, it won't repeat often enough for a cache. We need to cache it
    # on the board, but not the user, and include both the protected URL and the fallback
    # and then in-process we can decide which one to show. Even that won't be too 
    # often but at least it'll work across users
    # TODO: can we cache both the protected URL and the fallback on the db record itself,
    # based on boards_updated_at, and then we could skip the lookup entirely 
    # (how long is the lookup taking??? is this worth the effort?)
    # list_key = "images_and_sounds_with_fallbacks"
    key = "images_and_sounds_for/#{user ? user.cache_key : 'nobody'}"
    res = get_cached(key)
    return res if res
    Rails.logger.warn('start images_and_sounds lookup')
    res = {}
    bis = self.known_button_images
    # NOTE: enabled_protected_sources is already cached
    protected_sources = (user && user.enabled_protected_sources(true)) || []
    ButtonImage.cached_copy_urls(bis, user, nil, protected_sources)
    # JsonApi::Image.as_json(i, :original_and_fallback => true).slice('id', 'url', 'fallback_url', 'protected_source'))
    pref = user && user.settings['preferences']['preferred_symbols']
    include_other_sources = user && (user.supporter_role? || (user.settings['preferences']['preferred_symbols'] || 'original') != 'original')
    res['images'] = bis.map{|i| JsonApi::Image.as_json(i, :preferred_source => pref, :include_other_sources => include_other_sources, :allowed_sources => protected_sources) }
    if (self.buttons || []).detect{|b| b && b['sound_id']}
      res['sounds'] = self.known_button_sounds.map{|s| JsonApi::Sound.as_json(s) }#.slice('id', 'url') }
    else
      res['sounds'] = []
    end
    # set_cached(list_key, res.to_json)
    # res['images'].each do |img|
    #   if img['protected_source'] && !protected_sources.include?(img['protected_source'])
    #     img['url'] = img['fallback_url']
    #     img['protected'] = false
    #     img['fallback'] = true
    #   end
    #   img.delete('fallback_url')
    # end
    Rails.logger.warn('end images_and_sounds lookup')
    # This fills up half the cache, so no.
    # set_cached(key, res)
    res
  end

  def reload
    @button_images = nil
    super
  end

  def known_button_images
    # if self.settings && self.settings['images_not_mapped']
      return @button_images if @button_images
      image_ids = self.grid_buttons.map{|b| b['image_id'] }.compact.uniq
      @button_images = ButtonImage.find_all_by_global_id(image_ids)
    # else
    #   self.button_images
    # end
  end

  def known_button_sounds
    if self.settings && self.settings['images_not_mapped']
      return @button_sounds if @button_sounds
      sound_ids = self.buttons.map{|b| b['sound_id'] }.compact.uniq
      @button_sounds = ButtonSound.find_all_by_global_id(sound_ids)
    else
      self.button_sounds
    end
  end

  def import_translation(translated_copy, locale, overwrite=false)
    raise "only copies can be imported for now" unless translated_copy.parent_board == self
    raise "shallow clones cannot be updated" if @sub_id
    self.settings['translations'] ||= {}
    buttons = self.buttons
    translated_copy.settings['translations'] ||= {}
    translated_copy.settings['translations'].each do |btn_or_ref, locs_hash|
      if btn_or_ref == 'board_name' || buttons.detect{|b| b['id'].to_s == btn_or_ref.to_s}
        self.settings['translations'][btn_or_ref] ||= {}
        locs_hash.each do |loc, hash|
          if loc == locale && (!self.settings['translations'][btn_or_ref][loc] || overwrite)
            self.settings['translations'][btn_or_ref][loc] = hash
          end
        end
      end
    end
    self.save
  end

  def translate_set(translations, opts)
    allow_fallbacks = opts['allow_fallbacks']
    source_lang = opts['source']
    dest_lang = opts['dest']
    board_ids = opts['board_ids']
    set_as_default = opts['default'] != false
    user_for_paper_trail = opts['user_key']
    user_local_id = opts['user_local_id']
    visited_board_ids = opts['visited_board_ids'] || []

    user_local_id ||= self.user_id
    source_lang = 'en' if source_lang.blank?
    label_lang = dest_lang
    vocalization_lang = dest_lang
    return {done: true, translated: false, reason: 'mismatched user'} if user_local_id != self.user_id
    raise "can't translate for a shallow clone" if @sub_id
    set_as_default_here = !!set_as_default
    set_as_default_here = false if self.settings['locale'] == label_lang
    if board_ids.blank? || board_ids.include?(self.global_id)
      self.settings['translations'] = BoardContent.load_content(self, 'translations') || {}
      self.settings['translations']['board_name'] ||= {}
      if self.settings['name'] && self.settings['name'] != "Unnamed Board"
        self.settings['translations']['board_name'][source_lang] ||= self.settings['name']
        self.settings['translations']['board_name'][dest_lang] = translations[self.settings['name']] if translations[self.settings['name']]
      end
      if self.settings['name'] && translations[self.settings['name']] && set_as_default_here
        self.settings['name'] = translations[self.settings['name']]
      end
      self.settings['locale'] ||= source_lang
      self.settings['translations']['default'] ||= source_lang
      self.settings['translations']['current_label'] ||= source_lang
      self.settings['translations']['current_vocalization'] ||= source_lang
      if set_as_default_here
        self.settings['locale'] = label_lang
        self.settings['translations']['current_label'] = label_lang
        self.settings['translations']['current_vocalization'] = vocalization_lang
      end
      buttons = self.buttons
      buttons = self.buttons.map do |button|
        button = button.dup
        if button['label'] && translations[button['label']]
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang]['label'] ||= button['label']
          self.settings['translations'][button['id'].to_s][dest_lang] ||= {}
          self.settings['translations'][button['id'].to_s][dest_lang]['label'] = translations[button['label']]
          button['label'] = translations[button['label']] if set_as_default_here
          @buttons_changed = 'translated'
        elsif allow_fallbacks && set_as_default_here
          fallback = ((self.settings['translations'][button['id'].to_s] || {})[dest_lang] || {})['label']
          if fallback
            button['label'] = fallback 
            @buttons_changed = 'translated'
          elsif button['label']
            button.delete('label')
            @buttons_changed = 'translated'
          end
        end
        if button['vocalization'] && translations[button['vocalization']]
          self.settings['translations'][button['id'].to_s] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang] ||= {}
          self.settings['translations'][button['id'].to_s][source_lang]['vocalization'] ||= button['vocalization']
          self.settings['translations'][button['id'].to_s][dest_lang] ||= {}
          self.settings['translations'][button['id'].to_s][dest_lang]['vocalization'] = translations[button['vocalization']]
          button['vocalization'] = translations[button['vocalization']] if set_as_default_here
          @buttons_changed = 'translated'
        elsif  allow_fallbacks && set_as_default_here
          fallback = ((self.settings['translations'][button['id'].to_s] || {})[dest_lang] || {})['vocalization']
          if fallback
            button['vocalization'] = fallback 
            @buttons_changed = 'translated'
          elsif button['vocalization']
            button.delete('vocalization')
            @buttons_changed = 'translated'
          end
        end
        if allow_fallbacks && set_as_default_here
          fallback = ((self.settings['translations'][button['id'].to_s] || {})[dest_lang] || {})['inflections']
          if fallback
            button['inflections'] = fallback 
            @buttons_changed = 'translated'
          elsif button['inflections']
            button.delete('inflections')
            @buttons_changed = 'translated'
          end
        end
        button
      end
      if @buttons_changed
        self.settings['buttons'] = buttons
      end
      whodunnit = PaperTrail.request.whodunnit
      PaperTrail.request.whodunnit = user_for_paper_trail.to_s || 'user:unknown'
      self.save
      PaperTrail.request.whodunnit = whodunnit
      if self.public
        # When a board is translated, pass the new strings
        # along to opensymbols
        images_to_track = []
        images_hash = {}
        self.known_button_images.each{|i| images_hash[i.global_id] = i.settings['external_id'] }
        inverted_translations = translations.invert
        self.buttons.each do |button|
          string_to_track = button['label'] && translations[button['label']]
          string_to_track ||= inverted_translations[button['label']] && button['label']
          if string_to_track && button['image_id'] && images_hash[button['image_id']]
            images_to_track << {
              :id => button['image_id'], 
              :label => string_to_track, 
              :user_id => self.user.global_id,
              :external_id => images_hash[button['image_id']],
              :locale => dest_lang
            }
          end
        end
        ButtonImage.track_images(images_to_track)
      end
    else
      return {done: true, translated: false, reason: 'board not in list'}
    end
    visited_board_ids << self.global_id
    downstreams = self.get_immediately_downstream_board_ids - visited_board_ids
    Board.find_all_by_path(downstreams).each do |brd|
      brd.translate_set(translations, {
        'source' => source_lang,
        'dest' => dest_lang,
        'board_ids' => board_ids,
        'default' => set_as_default,
        'user_key' => user_for_paper_trail,
        'user_local_id' => user_local_id,
        'allow_fallbacks' => allow_fallbacks,
        'visited_board_ids' => visited_board_ids
      })
      visited_board_ids << brd.global_id
    end
    {done: true, translations: translations, d: dest_lang, s: source_lang, board_ids: board_ids, updated: visited_board_ids}
  end

  def update_privacy(privacy_level, author, board_ids, user_local_id=nil, visited_board_ids=[], updated_board_ids=[])
    author = User.find_by_global_id(author) if author && author.is_a?(String)
    user_local_id ||= self.user_id
    return {done: true, updated: false, reason: 'mismatched user'} if user_local_id != self.user_id
    return {done: true, updated: false, reason: 'no privacy level specified'} if !privacy_level || privacy_level.blank?
    return {done: true, updated: false, reason: 'author required'} unless author
    update_board = self
    if @sub_id
      return {done: true, updated: false, reason: 'unauthorized'} unless self.allows?(@sub_global, 'edit') 
      update_board = self.copy_for(@sub_global, skip_save: true, skip_user_update: true,)
    end
    if (board_ids.blank? || board_ids.include?(self.global_id))
      updated_board_ids << self.global_id
      whodunnit = PaperTrail.request.whodunnit
      PaperTrail.request.whodunnit = "user:#{author.global_id}.board.swap_images"
      update_board.public = (privacy_level == 'public'|| privacy_level == 'unlisted')
      update_board.settings['unlisted'] = (privacy_level == 'unlisted')
      update_board.instance_variable_set('@map_later', true)
      update_board.instance_variable_set('@edit_description', {
        'timestamp' => Time.now.to_f,
        'notes' => 'batch set to public'
      })
      update_board.save 
      PaperTrail.request.whodunnit = whodunnit
    else
      return {done: true, updated: false, reason: 'board not in list'}
    end
    visited_board_ids << self.global_id
    downstreams = self.get_immediately_downstream_board_ids - visited_board_ids
    Board.find_all_by_path(downstreams).each do |brd|
      brd.update_privacy(privacy_level, author, board_ids, user_local_id, visited_board_ids, updated_board_ids)
      visited_board_ids << brd.global_id
    end
    update_board.schedule_update_available_boards('all') if update_board.id
    {done: true, privacy_level: privacy_level, board_ids: board_ids, visited: visited_board_ids.uniq, updated: updated_board_ids.uniq}
  end

  def current_library(frd=nil)
    if self.settings && self.settings['swapped_library']
      return self.settings['swapped_library']
    else
      return self.settings['common_library'] if self.settings['common_library'] && frd == false
      if frd
        votes = {}
        res = 'opensymbols'
        self.known_button_images.each do |bi|
          lib = bi.image_library || 'unknown'
          if ['arasaac', 'twemoji', 'noun-project', 'sclera', 'mulberry', 'tawasol'].include?(lib)
            votes['opensymbols'] = (votes['opensymbols'] || 0) + 1
          end            
          if lib != 'unknown'
            votes[lib] = (votes[lib] || 0) + 1
          end
        end
        sorted = votes.to_a.sort_by{|a, b| b}
        if sorted[-1]
          res = sorted[-1][0]
          if res == 'opensymbols' && sorted[-2]
            if sorted[-2][1] > (sorted[-1][1] * 3 / 4) && ['arasaac', 'tawasol', 'twemoji', 'mulberry', 'noun-project'].include?(sorted[-2][0])
              res = sorted[-2][0]
            end
          end
        end
        self.settings['common_library'] = res
        self.save_subtly
        return res
      elsif !RedisInit.any_queue_pressure?
        self.schedule(:current_library, true)
      end
    end
    'opensymbols'
  end
  
  def swap_images(library, author, board_ids, user_local_id=nil, visited_board_ids=[], updated_board_ids=[])
    author = User.find_by_global_id(author) if author && author.is_a?(String)
    user_local_id ||= self.user_id
    copy_id = (board_ids || []).detect{|id| id.match(/^new/)}
    copy_id = copy_id.split(/:/)[1] if copy_id
    return {done: true, id: self.global_id, swapped: false, reason: 'mismatched user'} if user_local_id != self.user_id
    return {done: true, id: self.global_id, swapped: false, reason: 'no library specified'} if !library || library.blank?
    return {done: true, id: self.global_id, swapped: true, reason: 'kept same'} if library == 'original' || library == 'default'
    return {done: true, id: self.global_id, swapped: false, reason: 'author required'} unless author
    return {done: true, id: self.global_id, swapped: false, reason: 'not authorized to access premium library'} if library == 'pcs' && (!author || !author.subscription_hash['extras_enabled'])
    return {done: true, id: self.global_id, swapped: false, reason: 'not authorized to access premium library'} if library == 'symbolstix' && (!author || !author.subscription_hash['extras_enabled'])
    return {done: true, id: self.global_id, swapped: false, reason: 'not authorized to access premium library'} if library == 'lessonpix' && (!author || !author.subscription_hash['extras_enabled']) && !Uploader.lessonpix_credentials(author)
    swap_board = self
    swap_board_id = swap_board.global_id
    if @sub_id
      return {done: true, id: self.global_id, swapped: false, reason: 'unauthorized'} unless self.allows?(@sub_global, 'view') 
      swap_board = self.copy_for(@sub_global, skip_save: true, skip_user_update: true)
    end
    is_root = visited_board_ids.blank?
    # puts "SWAPPING FOR #{self.key} #{is_root}"
    cache = library.instance_variable_get('@library_cache')
    cache ||= LibraryCache.find_or_create_by(library: library, locale: swap_board.settings['locale'] || 'en')
    library.instance_variable_set('@library_cache', cache)
    cache.instance_variable_set('@ease_saving', true) if is_root
    if (board_ids.blank? || board_ids.include?(swap_board_id) || (copy_id && swap_board.settings['copy_id'] == copy_id))
      updated_board_ids << swap_board_id
      if !library.instance_variable_get('@skip_swapped') || swap_board.current_library(true) != library
        # puts " checking if important"
        words = swap_board.buttons.map{|b| [b['label'], b['vocalization']] }.flatten.compact.uniq
        # Important boards (i.e. boards that show up in the suggested list), should
        # definitely have their swap alternates cached indefinitely
        important_board = false
        if swap_board.settings['never_edited'] && swap_board.settings['source_board_id']
          ref = (swap_board.settings['copy_id'] && Board.find_by_path(swap_board.settings['copy_id'])) || swap_board
          sb = ref.source_board
          important_user = library.instance_variable_get('@important_user') || User.find_by_path('important_stars')
          library.instance_variable_set('@important_user', important_user)
          if sb && sb != swap_board && sb.starred_by?(important_user)
            important_board = true
          end
        end
        # puts " checking for default images"
        defaults = Uploader.default_images(library, words, swap_board.settings['locale'] || 'en', author, true, important_board)
        # puts " mapping buttons"
        bis = swap_board.known_button_images
        # TODO: for images that have the correct library in library_alternates, don't look them up, just use that
        buttons = swap_board.buttons.map do |button|
          # skip buttons that don't currently have an image
          next button unless button['image_id']
          next button if button['label'] && button['label'].match(/CoughDrop/)
          old_bi = bis.detect{|i| i.global_id == button['image_id'] }
          # skip buttons that have manually-uploaded image
          if old_bi && old_bi.url && old_bi.url.match(/coughdrop-usercontent/)
            # puts "SAFE PIC"
          elsif library.instance_variable_get('@skip_swapped') && (old_bi.image_library == library || (['arasaac', 'twemoji', 'noun-project', 'sclera', 'mulberry', 'tawasol'].include?(old_bi.image_library) && library == 'opensybmols'))
            # puts "ALREADY SWAPPED"
          elsif false
            # TODO: create or find an alternate version of the button_image that
            # uses the library_alternates version as the fault and puts the current default
            # into library_alternates instead
          elsif (button['label'] || button['vocalization'])
            image_data = defaults[button['label'] || button['vocalization']]
            if !image_data && (!defaults['_missing'] || !defaults['_missing'].include?(button['label'] || button['vocalization']))
              # puts " SEARCHING FOR #{button['label']}"
              image_data ||= (Uploader.find_images(button['label'] || button['vocalization'], library, 'en', author, nil, true, important_board) || [])[0]
            end
            new_bi = ButtonImage.find_by_global_id(image_data['coughdrop_image_id']) if image_data && image_data['coughdrop_image_id']
            if new_bi
              button['image_id'] = new_bi.global_id
              new_bi.assert_fallback(old_bi)
              @buttons_changed = 'swapped images'
            elsif image_data
              # puts " GENERATING BUTTONIMAGE"
              image_data['button_label'] = button['label']
              new_bi = ButtonImage.process_new(image_data, {user: author})
              new_bi.assert_fallback(old_bi)
              button['image_id'] = new_bi.global_id
              @buttons_changed = 'swapped images'
            end
          end
          button
        end
        # puts " saving"
      end
      whodunnit = PaperTrail.request.whodunnit
      PaperTrail.request.whodunnit = "user:#{author.global_id}.board.swap_images"
      if @buttons_changed
        swap_board.settings['buttons'] = buttons
        swap_board.settings['swapped_library'] = library
        @map_later = true
        swap_board.save 
      end
      PaperTrail.request.whodunnit = whodunnit
    else
      return {done: true, id: self.global_id, swapped: false, reason: 'board not in list'}
    end
    visited_board_ids << swap_board.global_id
    downstreams = self.get_immediately_downstream_board_ids - visited_board_ids
    Board.find_all_by_path(downstreams).each do |brd|
      if board_ids.instance_variable_get('@skip_keyboard') && brd.key.match(/keyboard$/)
        # When swapping images, don't touch the keyboards, 
        # there's no point and the pic will get weird via search
      else
        res = brd.swap_images(library, author, board_ids, user_local_id, visited_board_ids, updated_board_ids)
        brd = Board.find_by_global_id(res[:id]) if res[:id] && res[:id] != brd.global_id
      end
      visited_board_ids << brd.global_id
    end
    if is_root
      cache.instance_variable_set('@ease_saving', false)
      cache.save_if_added 
    end
    {done: true, id: swap_board.global_id, library: library, board_ids: board_ids, visited: visited_board_ids.uniq, updated: updated_board_ids.uniq}
  end  
  
  def default_listeners(notification_type)
    if notification_type == 'board_buttons_changed'
      ubc = UserBoardConnection.where(:board_id => self.id)
      direct_users = ubc.map(&:user).compact
      supervisors = direct_users.map(&:supervisors).flatten
      (direct_users + supervisors).uniq.map(&:record_code)
    else
      []
    end
  end
  
  def additional_webhook_record_codes(notification_type, additional_args)
    if notification_type == 'button_action' && additional_args && additional_args['button_id']
      button = (self.buttons || []).detect{|b| b['id'].to_s == additional_args['button_id'].to_s }
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
      button = (self.buttons || []).detect{|b| b['id'].to_s == additional_args['button_id'].to_s }
      res = {}
      user = additional_args && User.find_by_path(additional_args['user_id'])
      if button && button['integration'] && button['integration']['user_integration_id'] && self.allows?(user, 'view')
        ui = UserIntegration.find_by_path(button['integration']['user_integration_id'])
        associated_user = additional_args && User.find_by_path(additional_args['associated_user_id'])
        associated_user = nil if associated_user && !associated_user.allows?(user, 'model')
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

  def correct_parts_of_speech(do_update=false)
    # TODO: words needing inflections: +n't, I use a computer to help me talk., I use a computer to help me talk., I will tell you, I just need a minute., I will tell you, I just need a minute., Kazakhstan, Miss, Miss, This app is called CoughDrop, accessible, airplane, airplane, alligator, alligator, ambulance, ambulance, amphibian, amphibian, anniversary, anniversary, anxious, anxious, anything, apple juice, apple juice, appliance, appliance, apricot, apron, arms, art, average, baby, baby, baby, baby animal, baby animal, backpack, bacon, bacon, badger, bagel, bagel, bake, bake, banana, banana, basketball, basketball, bathroom, bathroom, bear, bear, bedroom, bedroom, big, big, big, big, big, big, big, big, blueberry, bowling, bowling, bowling alley, brachiosaurus, breakfast, breakfast, broccoli, broccoli, bronze, bronze, bus, bus, bus driver, bus driver, butter, butter, candy, candy, cantaloupe, car, car, case, caterpillar, cauliflower, cents, cereal, cereal, challenge, change, change, cheddar, cheese, cheese, cheese, cheesecake, cheetos, chest pain, chew, chicken, chicken, chicken, chipmunk, clean, clean, clear, clear, cloudy, cloudy, coconut, coffee maker, cold, cold, cold, cold, cold, comfortable, comfortable, complain, computer, computer, conditioner, confident, contagious, contagious, cool, cool, copy, cow, cow, cream, cream, credit card, crocodile, cucumber, cucumber, d, d, dangerous, death, decorate, decorate, delete, delicious, deodorant, deodorant, depressed, depressed, design, device, die, different, different, different, different, different, different, difficult, difficult, difficult, dig, dig, dime, dinosaur, dinosaur, direction, dishwasher, dishwasher, divide, divide, doctor, doctor, doctor, doctor, doctor's office, doctor's office, dog, dog, dog, dollar, dollar, don't, don't, don't, don't, don't, donkey, dragon, dragon, dress, dress, dress, drunk, drunk, edit, elephant, elephant, elliptical, else, embarrassed, embarrassed, enchilada, enchilada, enough, enough, erase, erase, excited, excited, exercise, expensive, expensive, experience, family, family, famous, felt, field, field, finally, fire truck, fire truck, food, food, food, food, fox, freezing, french fries, french fries, fresh, fresh, friend 1, friend 2, frog, frog, frog, frustrated, fry, fry, furious, garbage truck, garbage truck, gecko, gerbil, ghost, ghost, giant, giant, giraffe, giraffe, goddess, good morning, gorilla, grapefruit, grasshopper, grasshopper, great, great, greetings, grilled cheese, grow, grow, growth, guinea pig, gummy bear, gummy worm, gym, gymnastics, gymnastics, hamburger, hamburger, happy, happy, happy, headache, headache, hearing aid, heart, heart, helicopter, helicopter, hermit crab, highlighter, home, home, home, home, homework, homework, horse, horse, hot dog, hot dog, hot sauce, how are you?, how are you?, hula hoop, hungry, hungry, hungry, hurricane, hydrogen, hydrogen, hygiene, i, identify, jealous, kangaroo, ketchup, ketchup, keyboard, kitchen, kitchen, knife, knife, ladybug, ladybug, language, lasagna, lasagna, laundry, laundry, lawn mower, lawn mower, legs, legs, leopard, library, library, library, lion, lion, list, little, little, little, little, little, little, little, living room, living room, lollipop, lollipop, love, love, love, lunch, lunch, magazine, mail carrier, mail carrier, mail truck, marriage, maybe, maybe, memory, microwave, microwave, milkshake, milkshake, mirror, mirror, mom, mom, mom, monkey, motorcycle, motorcycle, mountain, mountain, mountain, mozzarella, mushroom, mushroom, music, music, mustache, nail clippers, nail polish, name, name, newspaper, nickel, note, note, notebook, numbers, octopus, octopus, oops, orchestra, p, p, paintbrush, paintbrush, palette, palm tree, pants, pants, pants, paper towel, paper towel, paragraph, password, pasta, pasta, peacock, peanut butter, peanut butter, pencil, pencil, penny, pentagon, people, people, people, people, perfect, perfume, perfume, phoenix, photo album, phrases, pine tree, pineapple, pirate, pizza, pizza, places, playground, playground, playstation, playstation, plum, pocket, police car, police car, police officer, police officer, pomegranate, pool, pool, poor, popcorn, popcorn, post office, post office, post office, pray, pray, pretend, pretend, problem, problem, pudding, q, q, quarter, quarter, quesadilla, quesadilla, question mark, questions, raccoon, raspberry, raspberry, ravioli, receive, record, remember, remember, repetition, restaurant, restaurant, restaurant, rhinoceros, rhinoceros, ride, ride, roller coaster, root beer, root beer, s, s, sad, sad, sad, sad, salamander, sausage, sausage, saxophone, saxophone, school, school, school, school, scient fiction, scrambled eggs, screwdriver, screwdriver, seal, seal, seaweed, seaweed, send, shaving cream, sick, sick, sick, sick, skateboard, skateboard, skateboarding, skateboarding, sky, smart board, snack, snack, snake, snake, social studies, soldier, soldier, sore, sore, sore throat, soup, soup, sour cream, sour cream, spaghetti, spaghetti, speaker, specialist, speech, speech, spell, spell, squirrel, squirrel, squish, stapler, start, start, stegosaurus, stegosaurus, stinky, straight, straight, strawberry, strawberry, strength, stretch, stretch, style, style, submarine, submarine, subway, subway, support, sweater, sweatshirt, sweet and sour, sweet and sour, swing, swing, swing, table, table, telescope, telescope, therapist, therapist, thirsty, thirsty, thirsty, throat, tired, tired, tired, toilet paper, toilet paper, tomato, tomato, tomorrow, tomorrow, tomorrow, toothbrush, toothbrush, toothpaste, toothpaste, tow truck, train, train, trampoline, trampoline, treadmill, triceratops, triceratops, tweet, ugly, ugly, ugly, unbutton, uncomfortable, uncomfortable, underwear, underwear, underwear, unicorn, unicorn, v, v, velociraptor, veterinarian, veterinarian, video game, video game, visitor, visitor, w, w, waiter, watermelon, watermelon, weather, weather, weights, whale, whale, whatever, whatever, wheelchair, wheelchair, wheelchair, whisper, woman, woman, woman, wonderful, wonderful, wrapping paper, wrestling, write, write, write, xylophone, yesterday, yesterday, yesterdaydo_update = true
    return unless self.locale == 'en'
    board = self
    missing = []
    type_colors = {
      "rgb(204, 255, 170)" => ['verb'],
      "rgb(170, 204, 255)" => ['adverb', 'adjective'],
      "rgb(255, 255, 170)" => ['pronoun'],
      "rgb(255, 170, 204)" => ['social'],
      "rgb(204, 170, 136)" => ['adverb'],
      "rgb(204, 204, 204)" => ['article', 'determiner'],
      "rgb(255, 255, 255)" => ['verb'],
      "rgb(255, 204, 170)" => ['noun']
    }
    words = WordData.where(locale: 'en', word: board.buttons.map{|b| b['label'] }.compact.uniq)
    changed = false
    buttons = board.buttons
    buttons.each do |btn|
      wrd = words.detect{|w| w.word == btn['label'] }
      if wrd && (wrd.data['types'] || [])[0] != btn['part_of_speech']
        if wrd.data['types'] && btn['background_color']
          #puts "#{btn['label']} #{btn['background_color']} #{btn['part_of_speech']} #{wrd.data['types'][0]}"
          if (type_colors[btn['background_color']] || []).include?(wrd.data['types'][0])
            if do_update
              btn['part_of_speech'] = wrd.data['types'][0]
              changed = true
            end
            puts "  #{btn['label']} should be #{(wrd.data['types'] || ['unknown'])[0]} not #{btn['part_of_speech']}?"
          end
        else
          missing << btn['label']
        end
      end
    end.length
    if changed
      board.settings['buttons'] = buttons
      board.instance_variable_set('@edit_notes', ["fixed buttons"])
      board.instance_variable_set('@buttons_changed', 'buttons processed')
      board.save
      puts "  UPDATED"
    end
    missing
  end

  def self.check_for_variants(board_id, force=false)
    board = Board.find_by_path(board_id)
    return false unless board
    changed = false
    board.known_button_images.each do |bi|
      changed = true if bi.check_for_variants(force)
    end
    if changed
      board.touch
    end
    !!changed
  end

end
