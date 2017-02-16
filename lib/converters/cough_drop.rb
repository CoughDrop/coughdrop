require 'obf'

module Converters::CoughDrop
  def self.to_obf(board, dest_path, path_hash=nil)
    json = to_external(board)
    OBF::External.to_obf(json, dest_path, path_hash)
  end
  
  def self.to_external(board)
    res = OBF::Utils.obf_shell
    res['id'] = board.global_id
    res['name'] = board.settings['name']
    res['locale'] = board.settings['locale'] || 'en'
    res['default_layout'] = 'landscape'
    res['url'] = "#{JsonApi::Json.current_host}/#{board.key}"
    res['data_url'] = "#{JsonApi::Json.current_host}/api/v1/boards/#{board.key}"
    res['description_html'] = board.settings['description'] || "built with CoughDrop"
    res['license'] = OBF::Utils.parse_license(board.settings['license'])
    res['ext_coughdrop_settings'] = {
      'private' => !board.public,
      'key' => board.key,
      'word_suggestions' => !!board.settings['word_suggestions'],
      'protected' => board.protected_material?
    }
    if board.protected_material? && board.user
      res['protected_content_user_identifier'] = board.user.settings['email']
    end
    grid = []
    res['buttons'] = []
    button_count = board.settings['buttons'].length
    board.settings['buttons'].each_with_index do |original_button, idx|
      button = {
        'id' => original_button['id'],
        'label' => original_button['label'],
        'left' => original_button['left'],
        'top' => original_button['top'],
        'width' => original_button['width'],
        'height' => original_button['height'],
        'border_color' => original_button['border_color'] || "#aaa",
        'background_color' => original_button['background_color'] || "#fff",
        'hidden' => original_button['hidden'],
      }
      if original_button['vocalization']
        if original_button['vocalization'].match(/^(\:|\+)/)
          button['action'] = original_button['vocalization']
        else
          button['vocalization'] = original_button['vocalization']
        end
      end
      if original_button['load_board']
        button['load_board'] = {
          'id' => original_button['load_board']['id'],
          'url' => "#{JsonApi::Json.current_host}/#{original_button['load_board']['key']}",
          'data_url' => "#{JsonApi::Json.current_host}/api/v1/boards/#{original_button['load_board']['key']}"
        }
      end
      if original_button['url']
        button['url'] = original_button['url']
      end
      if original_button['link_disabled']
        button['ext_coughdrop_link_disabled'] = original_button['link_disabled']
      end
      if original_button['add_to_vocalization'] != nil
        button['ext_coughdrop_add_to_vocalization'] = original_button['add_to_vocalization']
      end
      if original_button['home_lock']
        button['ext_coughdrop_home_lock'] = original_button['home_lock']
      end
      if original_button['part_of_speech']
        button['ext_coughdrop_part_of_speech'] = original_button['part_of_speech']
      end

      if original_button['apps']
        button['ext_coughdrop_apps'] = original_button['apps']
        if original_button['apps']['web'] && original_button['apps']['web']['launch_url']
          button['url'] = original_button['apps']['web']['launch_url']
        end
      end
      if original_button['image_id']
        image = board.button_images.detect{|i| i.global_id == original_button['image_id'] }
        if image
          image = {
            'id' => image.global_id,
            'width' => image.settings['width'],
            'height' => image.settings['height'],
            'license' => OBF::Utils.parse_license(image.settings['license']),
            'url' => image.url,
            'data_url' => "#{JsonApi::Json.current_host}/api/v1/images/#{image.global_id}",
            'content_type' => image.settings['content_type']
          }

          res['images'] << image
          button['image_id'] = image['id']
        end
      end
      if original_button['sound_id']
        sound = board.button_sounds.detect{|i| i.global_id == original_button['sound_id'] }
        if sound
          sound = {
            'id' => sound.global_id,
            'duration' => sound.settings['duration'],
            'license' => OBF::Utils.parse_license(sound.settings['license']),
            'url' => sound.url,
            'data_url' => "#{JsonApi::Json.current_host}/api/v1/sounds/#{sound.global_id}",
            'content_type' => sound.settings['content_type']
          }
        
          res['sounds'] << sound
          button['sound_id'] = original_button['sound_id']
        end
      end
      res['buttons'] << button
      Progress.update_current_progress(idx.to_f / button_count.to_f)
    end
    res['grid'] = board.settings['grid']
    res
  end
  
  def self.from_obf(obf_json_or_path, opts)
    json = OBF::External.from_obf(obf_json_or_path, opts)
    from_external(json, opts)
  end
  
  def self.from_external(json, opts)
    obj = OBF::Utils.parse_obf(json)

    raise "user required" unless opts['user']
    raise "missing id" unless obj['id']
    if obj['ext_coughdrop_settings'] && obj['ext_coughdrop_settings']['protected'] && obj['ext_coughdrop_settings']['key']
      user_name = obj['ext_coughdrop_settings']['key'].split(/\//)[0]
      raise "can't import protected boards to a different user" unless user_name == opts['user'].user_name
    end

    hashes = {}
    hashes['images_hash_ids'] = obj['buttons'].map{|b| b && b['image_id'] }.compact
    hashes['sounds_hash_ids'] = obj['buttons'].map{|b| b && b['sound_id'] }.compact
    [['images_hash', ButtonImage], ['sounds_hash', ButtonSound]].each do |list, klass|
      obj[list].each do |id, item|
        next unless hashes["#{list}_ids"].include?(item['id'])
        record = Converters::Utils.find_by_data_url(item['data_url'])
        if record
          obj[list][item['id']] = record.global_id
          hashes[item['id']] = record.global_id
        elsif item['data']
          record = klass.create(:user => opts['user'])
          item['ref_url'] = item['data']
        elsif item['url']
          record = klass.create(:user => opts['user'])
          item['ref_url'] = item['url']
        end
        if record && (!obj[list] || !obj[list][item['id']])
          item.delete('data')
          item.delete('url')

          if Uploader.valid_remote_url?(item['ref_url'])
            item['url'] = item['ref_url']
            item.delete('ref_url')
          end

          record.process(item)

          if item['ref_url']
            record.upload_to_remote(item['ref_url']) if item['ref_url']
          end
          obj[list] ||= {}
          obj[list][item['id']] = record.global_id
          hashes[item['id']] = record.global_id
        end
      end
    end

    params = {}
    non_user_params = {'user' => opts['user']}
    params['name'] = obj['name']
    params['description'] = obj['description_html']
    params['image_url'] = obj['image_url']
    params['license'] = OBF::Utils.parse_license(obj['license'])
    params['buttons'] = obj['buttons'].map do |button|
      new_button = {
        'id' => button['id'],
        'label' => button['label'],
        'left' => button['left'],
        'top' => button['top'],
        'width' => button['width'],
        'height' => button['height'],
        'border_color' => button['border_color'],
        'background_color' => button['background_color'],
        'hidden' => button['hidden']
      }
      if button['action']
        new_button['vocalization'] = button['action']
      elsif button['vocalization']
        new_button['vocalization'] = button['vocalization']
      end
      if button['image_id']
        new_button['image_id'] = hashes[button['image_id']]
      end
      if button['sound_id']
        new_button['sound_id'] = hashes[button['sound_id']]
      end
      if button['ext_coughdrop_link_disabled']
        new_button['link_disabled'] = button['ext_coughdrop_link_disabled']
      end
      if button['ext_coughdrop_part_of_speech']
        new_button['part_of_speech'] = button['ext_coughdrop_part_of_speech']
      end
      new_button['add_to_vocalization'] = button['ext_coughdrop_add_to_vocalization'] != false
      if button['ext_coughdrop_home_lock']
        new_button['home_lock'] = button['ext_coughdrop_home_lock']
      end

      if button['load_board']
        if opts['boards'] && opts['boards'][button['load_board']['id']]
          new_button['load_board'] = opts['boards'][button['load_board']['id']]
        else
          link = Board.find_by_path(button['load_board']['key'] || button['load_board']['id'])
          if link
            new_button['load_board'] = {
              'id' => link.global_id,
              'key' => link.key
            }
          end
        end
      elsif button['url']
        if button['ext_coughdrop_apps']
          new_button['apps'] = button['ext_coughdrop_apps']
        else
          new_button['url'] = button['url']
        end
      end
      new_button
    end
    params['grid'] = obj['grid']
    params['public'] = !(obj['ext_coughdrop_settings'] && obj['ext_coughdrop_settings']['private'])
    params['word_suggestions'] = obj['ext_coughdrop_settings'] && obj['ext_coughdrop_settings']['word_suggestions']
    non_user_params[:key] = (obj['ext_coughdrop_settings'] && obj['ext_coughdrop_settings']['key'] && obj['ext_coughdrop_settings']['key'].split(/\//)[-1])
    board = nil
    # TODO: I removed this because I don't think the user expectation is ever that
    # importing a file would overwrite existing files, but I'm open to persuasion..
#     board = Converters::Utils.find_by_data_url(obj['data_url'])
#     if board && board.allows?(opts['user'], 'edit')
#       board.process(params, non_user_params)
#     els
    if opts['boards'] && opts['boards'][obj['id']]
      board = Board.find_by_path(opts['boards'][obj['id']]['id']) || Board.find_by_path(opts['boards'][obj['id']]['key'])
      board.process(params, non_user_params)
    else
      board = Board.process_new(params, non_user_params)
    end
    opts['boards'] ||= {}
    opts['boards'][obj['id']] = {
      'id' => board.global_id,
      'key' => board.key
    }
    board
  end
  
  def self.to_obz(board, dest_path, opts)
    content = to_external_nested(board, opts)
    OBF::External.to_obz(content, dest_path, opts)
  end
  
  def self.to_external_nested(board, opts)
    boards = []
    images = []
    sounds = []

    board.track_downstream_boards!

    lookup_boards = [board]
    board.settings['downstream_board_ids'].each do |id|
      b = Board.find_by_path(id)
      if b && b.allows?(opts['user'], 'view')
        lookup_boards << b
      end
    end

    lookup_boards.each do |b|
      if b
        res = to_external(b)
        images += res['images']
        res.delete('images')
        sounds += res['sounds']
        res.delete('sounds')
        boards << res
      end
    end
      
    return {
      'boards' => boards,
      'images' => images.uniq,
      'sounds' => sounds.uniq
    }
  end
  
  def self.from_obz(obz_path, opts)
    content = OBF::External.from_obz(obz_path, opts)
    from_external_nested(content, opts)
  end
  
  def self.from_external_nested(content, opts)
    result = []
    
    # pre-load all the boards so they already exist when we go to look for them as links
    content['boards'].each do |obj|
    # TODO: I removed this because I don't think the user expectation is ever that
    # importing a file would overwrite existing files, but I'm open to persuasion..
#       board = Converters::Utils.find_by_data_url(obj['data_url'])
#       if board && board.allows?(opts['user'], 'edit')
#         board.process(params, non_user_params)
#       els
      if opts['boards'] && opts['boards'][obj['id']]
        board = Board.find_by_path(opts['boards'][obj['id']]['id']) || Board.find_by_path(opts['boards'][obj['id']]['key'])
      else
        non_user_params = {'user' => opts['user']}
        non_user_params[:key] = (obj['ext_coughdrop_settings'] && obj['ext_coughdrop_settings']['key'] && obj['ext_coughdrop_settings']['key'].split(/\//)[-1])
        params = {}
        params['name'] = obj['name']
        board = Board.process_new(params, non_user_params)
      end
      if board
        board.reload
        opts['boards'] ||= {}
        opts['boards'][obj['id']] = {
          'id' => board.global_id,
          'key' => board.key
        }
      end
    end
    
    sleep 10
    
    content['boards'].each do |board|
      # TODO: content['images'] and content['sounds'] may be helpful
      board['images'] = content['images'] || []
      board['sounds'] = content['sounds'] || []
      result << from_obf(board, opts)
    end
    return result
  end
  
  def self.to_pdf(board, dest_path, opts)
    json = nil
    Progress.as_percent(0, 0.5) do
      # TODO: break 
      if opts['packet']
        json = to_external_nested(board, opts)
      else
        json = to_external(board)
      end
    end
    res = nil
    Progress.as_percent(0.5, 1.0) do
      res = OBF::External.to_pdf(json, dest_path, opts)
    end
    return res
  end
  
  def self.to_png(board, dest_path)
    json = to_external(board)
    OBF::External.to_png(json, dest_path)
  end


  def self.from_csv(csv_path, opts)
    opts['id'] ||= csv_path.split('/').last.split('.').first
    self.from_csv_text(File.read(csv_path), opts)
  end

  def self.from_csv_text(csv_text, opts)
    order_flat = []
    buttons = []
    csv_text.split(/[\r\n]/).each do |button_csv|
      button_attrs = button_csv.split(',')
      button_attrs.each do |attr|
        attr.strip!
      end
      button = {}
      button['id'] = button_attrs[0]
      order_flat << button_attrs[0]

      button['label'] = button_attrs[1]

      button['vocalization'] = (if button_attrs[2] and button_attrs[2].length > 0
                                  button_attrs[2]
                                else
                                  button_attrs[1]
                                end)
      buttons << button
    end
    num_buttons = order_flat.length
    grid_dim = Math.sqrt(num_buttons).ceil
    grid = {'rows': grid_dim,
            'columns': grid_dim,
            'order': (0 .. grid_dim).map do |i|
              order_flat[i*grid_dim,grid_dim]
            end
    }
    board = Converters::Utils.obf_shell
    board['id'] = opts['id']
    board['buttons'] = buttons
    board['grid'] = grid
    return self.from_external(board, opts)
  end
end