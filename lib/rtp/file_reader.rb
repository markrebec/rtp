require_relative 'ffmpeg/ffmpeg'
require_relative 'ffmpeg/stream'
require_relative 'logger'


module RTP
  class FileReader
    include LogSwitch::Mixin
    include RTP::FFmpeg

    attr_reader :streams

    # @param [String] filename Path of the file to open.
    # @param [Hash] p ?
    def initialize(filename, p={})
      @filename = filename
      @streams = []

      FFmpeg.av_register_all
      @av_format_ctx = FFI::MemoryPointer.new(:pointer)
      #rc = av_open_input_file(@av_format_ctx, @filename, nil, 0, nil)
      return_code = FFmpeg.avformat_open_input(@av_format_ctx, @filename, nil, 0, nil)

      unless return_code.zero?
        raise RuntimeError, "av_open_input_file() failed, filename='%s', rc=%d" %
            [filename, return_code]
      end

      @av_format_ctx = AVFormatContext.new(@av_format_ctx.get_pointer(0))
      return_code = av_find_stream_info(@av_format_ctx)
      raise RuntimeError, "av_find_stream_info() failed, rc=#{return_code}" if return_code < 0

      initialize_streams(p)
    end

    def dump_format
      if FFmpeg.old_api?
        FFmpeg.dump_format(@av_format_ctx, 0, @filename, 0)
      else
        FFmpeg.av_dump_format(@av_format_ctx, 0, @filename, 0)
      end
    end

    # Video duration in (fractional) seconds
    def duration
      @duration ||= @av_format_ctx[:duration].to_f / AV_TIME_BASE
    end

    def each_frame(&block)
      raise ArgumentError, "No block provided" unless block_given?

      av_packet = avcodec_alloc_frame or
        raise NoMemoryError, "avcodec_alloc_frame() failed"
      av_packet = AVPacket.new(av_packet)

      while av_read_frame(@av_format_ctx, av_packet) >= 0
        log "packet number #{av_packet[:stream_index]}"
        frame = @streams[av_packet[:stream_index]].decode_frame(av_packet)
        rc = frame ? yield(frame) : true
        av_free_packet(av_packet)

        break if rc == false
      end

      av_free(av_packet)
    end

    def default_stream
      @streams[av_find_default_stream_index(@av_format_ctx)]
    end

    def seek(p = {})
      default_stream.seek(p)
    end

    private

    def initialize_streams(p={})
      log "Streams: #{@av_format_ctx[:nb_streams]}"
      log "video codec id: #{@av_format_ctx[:video_codec_id]}"
      log "video start time: #{@av_format_ctx[:start_time]}"
      log "video packet size: #{@av_format_ctx[:packet_size]}"

      @av_format_ctx[:nb_streams].times do |i|
        av_stream = AVStream.new(@av_format_ctx[:streams][i].get_pointer(0))
        #av_stream.members.each_with_index do |member, i|
        #  log "#{member}: #{av_stream.values.at(i)}"
        #end
        log "Stream index: #{av_stream[:index]}"
        log "Stream id: #{av_stream[:id]}"
        log "Stream codec: #{av_stream.codec}"
        log "Stream codec codec type: #{av_stream.codec[:codec_type]}"
        log "Stream codec type: #{av_stream.codec_type}"
        log "Stream codec bit rate: #{av_stream.bit_rate}"

        #@streams << case av_codec_ctx[:codec_type]
        @streams << case av_stream.codec_type
          when :video
            FFmpeg::Streams::Video.new(:reader => self,
              :av_stream => av_stream,
              :pixel_format => p[:pixel_format],
              :width => p[:width],
              :height => p[:height])
        else
          FFmpeg::Streams::Unsupported.new(:reader => self,
            :av_stream => av_stream)
        end

        # TODO: fix for 2nd stream
        break
      end
    end
  end
end