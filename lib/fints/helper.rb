module FinTS
  class Helper
    def self.fints_escape(content)
      content.gsub('?', '??').gsub('+', '?+').gsub(':', '?:').gsub("'", "?'")
    end

    def self.fints_unescape(content)
      content.gsub('??', '?').gsub("?'", "'").gsub('?+', '+').gsub('?:', ':')
    end

    def self.split_for_data_groups(seg)
      seg.split(/\+(?<!\?\+)/)
    end

    def self.split_for_data_elements(deg)
      deg.split(/:(?<!\?:)/)
    end
  end
end
