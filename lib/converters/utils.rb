module Converters::Utils
  def self.find_by_data_url(data_url)
    return nil unless data_url.is_a?(String)
    pre, path = data_url.split(/\/api\/v1\//)
    return nil unless path
    return nil unless pre == JsonApi::Json.current_host
    type, key = path.split(/\//, 2)
    if type == 'images'
      return ButtonImage.find_by_global_id(key)
    elsif type == 'sounds'
      return ButtonSound.find_by_global_id(key)
    elsif type == 'boards'
      return Board.find_by_path(key)
    end
    nil
  end
  
  def self.board_to_remote(board, user, file_type, include, headerless=false, text_on_top=false)
    Progress.update_current_progress(0.2, :converting_file)
    # TODO: key off just the last change id for the board(s) when building the
    # filename, return existing filename if it exists and isn't about to expire
    path = OBF::Utils.temp_path("stash")

    content_type = nil
    if file_type == 'obf'
      content_type = 'application/obf'
    elsif file_type == 'obz'
      content_type = 'application/obz'
    elsif file_type == 'pdf'
      content_type = 'application/pdf'
    else
      raise "Unrecognized conversion type: #{file_type}"
    end
    key = Security.sha512(board.id.to_s, 'board_id')
    
    filename = "board_" + board.current_revision + (include == 'all' ? '1' : '0') + (headerless ? '1' : '0') + (text_on_top ? '1' : '0') + "." + file_type.to_s
    remote_path = "downloads/#{key}/#{filename}"
    url = Uploader.check_existing_upload(remote_path)
    return url if url
    Progress.update_current_progress(0.3, :converting_file)
    
    Progress.as_percent(0.3, 0.8) do
      if file_type == 'obz'
        if include == 'all'
          Converters::CoughDrop.to_obz(board, path, {'user' => user})
        else
          Converters::CoughDrop.to_obz(board, path, {'user' => user, 'headerless' => !!headerless, 'text_on_top' => !!text_on_top})
        end
      elsif file_type == 'obf'
        Converters::CoughDrop.to_obf(board, path)
      elsif file_type == 'pdf'
        Converters::CoughDrop.to_pdf(board, path, {'user' => user, 'packet' => (include == 'all'), 'headerless' => !!headerless, 'text_on_top' => !!text_on_top})
      end
    end
    Progress.update_current_progress(0.9, :uploading_file)
    url = Uploader.remote_upload(remote_path, path, content_type)
    raise "File not uploaded" unless url
    File.unlink(path) if File.exist?(path)
    return url
  end
  
  def self.remote_to_boards(user, url)
    result = []
    Progress.update_current_progress(0.1, :downloading_file)
    response = Typhoeus.get(url)
    file = Tempfile.new('stash')
    file.binmode
    file.write response.body
    file.close
    Progress.update_current_progress(0.2, :processing_file)
    Progress.as_percent(0.2, 1.0) do
      if url.match(/\.obz$/) || response.headers['Content-Type'] == 'application/obz'
        boards = Converters::CoughDrop.from_obz(file.path, {'user' => user})
        result = boards
      elsif url.match(/\.obf$/) || response.headers['Content-Type'] == 'application/obf'
        board = Converters::CoughDrop.from_obf(file.path, {'user' => user})
        result = [board]
      elsif url.match(/\.csv$/) || response.headers['Content-Type'] == 'application/csv'
        board = Converters::CoughDrop.from_csv(file.path, {'user' => user})
        result = [board]
      else
        raise "Unrecognized file type: #{response.headers['Content-Type']}"
      end
      file.unlink
    end
    return result
  end
  
  def self.obf_shell
    {
      'format' => 'open-board-0.1',
      'license' => {'type' => 'private'},
      'buttons' => [],
      'grid' => {
        'rows' => 0,
        'columns' => 0,
        'order' => [[]]
      },
      'images' => [],
      'sounds' => []
    }
  end
end