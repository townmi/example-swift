//
//  VideoDecoder.swift
//  GTX660
//
//  Created by Harry Tang on 2019/6/3.
//  Copyright © 2019 Harry Tang. All rights reserved.
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreImage

public struct Frame {
	//	var type: FR
}

public struct AudioFrame {
	var frame:AVFrame? = nil
}

public struct VideoFrame {
	var width:Int32 = 0
	var height:Int32 = 0
	var linesize: Int32 = 0
	var frame: AVFrame? = nil
	var position:Double = 0
	var duration:Double = 0
	var buffer:CVPixelBuffer? = nil
}

var hw_pix_fmt: AVPixelFormat? = nil
var hw_device_ctx: UnsafeMutablePointer<AVBufferRef>? = nil
var MAX_AUDIO_FRAME_SIZE:Int32 = 192000

var audio_len: UInt32 = 0
var audio_pos: UnsafeMutablePointer<UInt8>? = nil

public func get_hw_format(ctx: UnsafeMutablePointer<AVCodecContext>?, pix_fmts: UnsafePointer<AVPixelFormat>?) -> AVPixelFormat {
	var p: AVPixelFormat = AV_PIX_FMT_NONE
	if pix_fmts != nil{
		p = pix_fmts!.pointee
		while p.rawValue != -1 {
			if p == hw_pix_fmt {
				return p
			}
			p.rawValue += 1
		}
	}
	print("Failed to get HW surface format.\n")
	return p
}

public func fill_audio(udata: UnsafeMutableRawPointer?, stream: UnsafeMutablePointer<UInt8>?, len:Int32) {
	
	SDL_memset(stream, 0, Int(len))
	
	if audio_len == 0 {
		return
	}
	var l = UInt32(len)
	if len > Int32(audio_len) {
		l = UInt32(audio_len)
	}
	SDL_MixAudio(stream, audio_pos, l, SDL_MIX_MAXVOLUME)
	audio_pos = audio_pos! + Int(l)
	audio_len -= l
}

class VideoDecoder {
	//
	static let shared = VideoDecoder()
	// video 流索引
	var videoStreamIndex:Int32 = -1
	var audioStreamIndex:Int32 = -1
	// video 流
	var videoStream: UnsafeMutablePointer<AVStream>? = nil
	var audioStream: UnsafeMutablePointer<AVStream>? = nil
	// frame
	var videoFrame: UnsafeMutablePointer<AVFrame>? = nil
	var audioFrame: UnsafeMutablePointer<AVFrame>? = nil
	// 上下文
	var formatContext: UnsafeMutablePointer<AVFormatContext>? = nil
	// 解码器上下文
	var videoCodecCtx: UnsafeMutablePointer<AVCodecContext>? = nil
	var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>? = nil
	//
	var videoDecoder: UnsafeMutablePointer<AVCodec>? = nil
	var audioDecoder: UnsafeMutablePointer<AVCodec>? = nil
	
	var pixelBufferPool: CVPixelBufferPool? = nil
	var pixelBuffer:CVPixelBuffer? = nil
	// SDL Audio
	var wanted_spec: SDL_AudioSpec? = nil
	var au_convert_ctx: OpaquePointer? = nil
	var out_buffer: UnsafeMutablePointer<UInt8>? = nil
	var out_buffer_size:Int32 = 0
	// SDL Video
	var screenWidth:Int32 = 0
	var screenHeight:Int32 = 0
	var screen:OpaquePointer? = nil
	var screenRender:OpaquePointer? = nil
	var screenTexture:OpaquePointer? = nil
	var screenRect:SDL_Rect = SDL_Rect.init()
	var screenThread:UnsafePointer<SDL_threadID>? = nil
	var screenEvent:SDL_Event = SDL_Event.init()
	
	
	// 处理放回结果
	var ret:Int32 = 0
	//
	//	var pixelBufferPool: CVPixelBufferPool? = nil
	var fps: CDouble = 0
	var videoTimeBase: CDouble = 0
	var isEOF = false
	var opened = false
	var type: AVHWDeviceType = av_hwdevice_find_type_by_name("videotoolbox") //MacOS和iOS可以固定写videotoolbox
	
	open func start(_ path: String?) -> Bool {
		avformat_network_init()
		
		let videoSourceURI = path?.cString(using: .utf8)
		
		if avformat_open_input(&formatContext, videoSourceURI, nil, nil) != 0 {
			print("Couldn't open file")
			if formatContext != nil {
				avformat_close_input(&formatContext)
			}
			return false
		}
		
		if avformat_find_stream_info(formatContext, nil) < 0 {
			print("Cannot find input stream information.\n")
			if formatContext != nil {
				avformat_close_input(&formatContext)
			}
			return false
		}
		
		/* find the video stream information */
		ret = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &videoDecoder, 0);
		if ret < 0 {
			print("Cannot find a video stream in the input file\n")
			return false;
		}
		videoStreamIndex = ret
		
		ret = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &audioDecoder, 0)
		if ret < 0 {
			print("Cannot find a audio stream in the input file\n")
			return false;
		}
		audioStreamIndex = ret
		
		var i:Int32 = 0
		while true {
			let config = avcodec_get_hw_config(videoDecoder, i)
			if config == nil {
				print("Decoder \(String(describing: videoDecoder?.pointee.name)) does not support device type \(String(describing: av_hwdevice_get_type_name(type))).\n")
			} else if ((config?.pointee.methods) != nil) && AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX != 0 && config?.pointee.device_type == type {
				hw_pix_fmt = config?.pointee.pix_fmt
				break
			}
			i += 1
		}
		
		videoCodecCtx = avcodec_alloc_context3(videoDecoder)
		if videoCodecCtx == nil {
			return false
		}
		
		audioCodecCtx = avcodec_alloc_context3(audioDecoder)
		if audioCodecCtx == nil {
			return false
		}
		
		videoStream = formatContext?.pointee.streams![Int(videoStreamIndex)]
		audioStream = formatContext?.pointee.streams![Int(audioStreamIndex)]
		
		
		if (videoStream!.pointee.time_base.den >= 1) && (videoStream!.pointee.time_base.num >= 1) {
			videoTimeBase = av_q2d(videoStream!.pointee.time_base)
		} else if (videoCodecCtx!.pointee.time_base.den >= 1) && (videoCodecCtx!.pointee.time_base.num >= 1) {
			videoTimeBase = av_q2d(videoCodecCtx!.pointee.time_base)
		} else {
			videoTimeBase = 0.04
		}
		
		if (videoCodecCtx!.pointee.ticks_per_frame != 1) {
			print("WARNING: ticks_per_frame")
		}
		if (videoStream!.pointee.avg_frame_rate.den >= 1) && (videoStream!.pointee.avg_frame_rate.num >= 1) {
			fps = av_q2d(videoStream!.pointee.avg_frame_rate)
		} else if (videoStream!.pointee.r_frame_rate.den >= 1) && (videoStream!.pointee.r_frame_rate.num >= 1) {
			fps = av_q2d(videoStream!.pointee.r_frame_rate)
		} else {
			fps = 1 / self.videoTimeBase
		}
		
		ret = avcodec_parameters_to_context(videoCodecCtx, videoStream?.pointee.codecpar)
		if ret < 0 {
			return false
		}
		
		ret = avcodec_parameters_to_context(audioCodecCtx, audioStream?.pointee.codecpar)
		if ret < 0 {
			return false
		}
		
		videoCodecCtx?.pointee.get_format = get_hw_format
		if av_hwdevice_ctx_create(&hw_device_ctx, type, nil, nil, 0) < 0 {
			print("Failed to create specified HW device.\n")
			return false
		}
		videoCodecCtx?.pointee.hw_device_ctx = av_buffer_ref(hw_device_ctx)
		
		
		ret = avcodec_open2(videoCodecCtx, videoDecoder, nil)
		if ret < 0 {
			print("Failed to open codec for stream \(String(videoStreamIndex))\n");
			return false;
		}
		
		ret = avcodec_open2(audioCodecCtx, audioDecoder, nil)
		if ret < 0 {
			print("Failed to open codec for stream \(String(audioStreamIndex))\n");
			return false;
		}
		
		av_dump_format(formatContext, 0, videoSourceURI, 0)
		opened = true
		
		
		return true
	}
	
	open func setVideo() {
		
		// SDL hanlder
		if SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER) != 0 {
			print("Could not initialize SDL - \(String(describing: SDL_GetError()))\n")
		}
		
		screenWidth = (videoCodecCtx?.pointee.width)!
		screenHeight = (videoCodecCtx?.pointee.height)!
		screen = SDL_CreateWindow("Simplest ffmpeg player's Window", Int32(SDL_WINDOWPOS_UNDEFINED_MASK), Int32(SDL_WINDOWPOS_UNDEFINED_MASK), screenWidth, screenHeight, SDL_WINDOW_OPENGL.rawValue);
		
		if screen == nil {
			print("SDL: could not create window - exiting:\(String(describing: SDL_GetError()))\n")
		}
		
		screenRender = SDL_CreateRenderer(screen, -1, 0)
		//IYUV: Y + U + V  (3 planes)
		//YV12: Y + V + U  (3 planes)
		screenTexture = SDL_CreateTexture(screenRender, Uint32(SDL_PIXELFORMAT_IYUV), Int32(SDL_TEXTUREACCESS_STREAMING.rawValue), screenWidth, screenHeight)
		
		screenRect.x = 0
		screenRect.y = 0
		screenRect.w = screenWidth
		screenRect.h = screenHeight
	}
	
	
	open func setAudio() -> Bool {
		var success = true
		
		// SDL hanlder
		if SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER) != 0 {
			print("Could not initialize SDL - \(String(describing: SDL_GetError()))\n")
			success =  false
		}
		
		let out_sample_rate:Int32 = 44100
		let out_channel_layout:UInt64 = UInt64(AV_CH_LAYOUT_STEREO)
		let out_channels = av_get_channel_layout_nb_channels(out_channel_layout)
		let out_nb_samples = (audioCodecCtx?.pointee.frame_size)!;
		let out_sample_fmt:AVSampleFormat = AV_SAMPLE_FMT_S16
		
		out_buffer_size = av_samples_get_buffer_size(nil, out_channels, out_nb_samples, out_sample_fmt, 1)
		let c = av_malloc(Int(MAX_AUDIO_FRAME_SIZE * 2))
		out_buffer = c?.assumingMemoryBound(to: UInt8.self)
		
		wanted_spec = SDL_AudioSpec.init()
		wanted_spec!.freq = out_sample_rate;
		wanted_spec!.format = SDL_AudioFormat(AUDIO_S16SYS);
		wanted_spec!.channels = Uint8(out_channels);
		wanted_spec!.silence = 0;
		wanted_spec!.samples =  Uint16(out_nb_samples);
		wanted_spec!.callback = fill_audio;
		wanted_spec!.userdata = UnsafeMutableRawPointer(audioCodecCtx);
		
		if SDL_OpenAudio(&wanted_spec!, nil) < 0{
			print("can't open audio.\n");
			success = false
		}
		
		let in_channel_layout = av_get_default_channel_layout((audioCodecCtx?.pointee.channels)!);
		//Swr
		au_convert_ctx = swr_alloc()
		au_convert_ctx = swr_alloc_set_opts(au_convert_ctx, Int64(out_channel_layout), out_sample_fmt, out_sample_rate, in_channel_layout, (audioCodecCtx?.pointee.sample_fmt)!, (audioCodecCtx?.pointee.sample_rate)!, 0, nil)
		swr_init(au_convert_ctx);
		
		//Play
		SDL_PauseAudio(0)
		
		return success
	}
	
	open func decode(_ minDuaration: Double) -> [VideoFrame] {
		var frame:UnsafeMutablePointer<AVFrame>? = nil
		var sw_frame:UnsafeMutablePointer<AVFrame>? = nil
		var tmp_frame:UnsafeMutablePointer<AVFrame>? = nil
		let packet = av_packet_alloc()
		var finished = false
		var decodedDuration = 0.0
		var videoResult:[VideoFrame] = []
		
		//		let out_buffer = av_malloc(av_image_get_buffer_size(AV_PIX_FMT_YUV420P,  videoCodecCtx?.pointee.width, videoCodecCtx?.pointee.height, 1))
		//		av_image_fill_arrays(tmp_frame?.pointee.data, tmp_frame?.pointee.linesize, out_buffer, AV_PIX_FMT_YUV420P, videoCodecCtx?.pointee.width, videoCodecCtx?.pointee.height, 1)
		//		av_samples_fill_arrays()
		//		let img_convert_ctx = sws_getContext(videoCodecCtx?.pointee.width, videoCodecCtx?.pointee.height, videoCodecCtx?.pointee.pix_fmt, videoCodecCtx?.pointee.width, videoCodecCtx?.pointee.height, AV_PIX_FMT_YUV420P, SWS_BICUBIC, nil, nil, nil);
		
		while !finished {
			ret = av_read_frame(formatContext, packet)
			if ret < 0 {
				isEOF = true
				break
			}
			
			if packet?.pointee.stream_index == audioStreamIndex {
				//				var v = AudioFrame()
				var ret2:Int32 = avcodec_send_packet(audioCodecCtx, packet);
				if (ret2 < 0) {
					print("Error during decoding\n")
				}
				while ret2 >= 0 {
					frame = av_frame_alloc()
					ret2 = avcodec_receive_frame(audioCodecCtx, frame)
					if ret2 < 0 {
						break
						print("Error while decoding\n")
					}
					
					var data = [UnsafePointer(frame?.pointee.data.0), UnsafePointer(frame?.pointee.data.1), UnsafePointer(frame?.pointee.data.2), UnsafePointer(frame?.pointee.data.3), UnsafePointer(frame?.pointee.data.4), UnsafePointer(frame?.pointee.data.5), UnsafePointer(frame?.pointee.data.6), UnsafePointer(frame?.pointee.data.7)]
					swr_convert(au_convert_ctx, &out_buffer, MAX_AUDIO_FRAME_SIZE, &data, (frame?.pointee.nb_samples)!);
					while audio_len > 0 {
						SDL_Delay(1)
					}
					//Audio buffer length
					audio_len = UInt32(out_buffer_size);
					//Set audio buffer (PCM data)
					audio_pos = out_buffer
					
				}
			}
			
			if packet?.pointee.stream_index == videoStreamIndex {
				var ret2:Int32 = avcodec_send_packet(videoCodecCtx, packet);
				if (ret2 < 0) {
					print("Error during decoding\n")
				}
				
				while ret2 >= 0 {
					frame = av_frame_alloc()
					sw_frame = av_frame_alloc()
					
					if frame == nil || sw_frame == nil {
						print("Can not alloc frame\n")
					}
					ret2 = avcodec_receive_frame(videoCodecCtx, frame)
					
					if ret2 < 0 {
						print("Error while decoding\n")
						break
					}
					
					var v = VideoFrame()
					if frame?.pointee.format == hw_pix_fmt!.rawValue {
						/* retrieve data from GPU to CPU */
						ret2 = av_hwframe_transfer_data(sw_frame, frame, 0)
						if ret2 < 0 {
							print("Error transferring the data to system memory\n")
						}
						tmp_frame = sw_frame;
					} else {
						tmp_frame = frame;
					}
					var duration = 0.0
					v.frame = tmp_frame?.pointee
					v.height = (videoCodecCtx?.pointee.height)!
					v.width = (videoCodecCtx?.pointee.width)!
					v.linesize = (tmp_frame?.pointee.linesize.0)!
					
					let frameDuration = av_frame_get_pkt_duration(tmp_frame)
					if frameDuration > 0 {
						duration = Double(frameDuration) * videoTimeBase
						duration += Double((tmp_frame?.pointee.repeat_pict)!) * videoTimeBase * 0.5
					} else {
						duration = 1.0 / fps
					}
					duration = 1.0 / fps
					
					v.duration = duration
					v.position = Double(av_frame_get_best_effort_timestamp(tmp_frame!)) * videoTimeBase
					v.buffer = f2i(in: v)
					videoResult.append(v)
					decodedDuration += duration
					if decodedDuration > minDuaration {
						finished = true
					}
				}
			}
			av_packet_unref(packet)
			av_frame_unref(frame)
			av_frame_unref(tmp_frame)
			av_frame_unref(sw_frame)
		}
		//		av_frame_free(&frame);
		//		av_frame_free(&tmp_frame)
		//		av_frame_free(&sw_frame)
		//
		return videoResult
	}
	
	
	func f2i(in vf: VideoFrame) -> CVPixelBuffer {
		
		var attributes: [AnyHashable : Any] = [:]
		attributes[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
		attributes[kCVPixelBufferWidthKey as String] = NSNumber(value: vf.width)
		attributes[kCVPixelBufferHeightKey as String] = NSNumber(value: vf.height)
		attributes[kCVPixelBufferBytesPerRowAlignmentKey as String] = NSNumber(value: vf.linesize)
		attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [AnyHashable : Any]()
		let theError = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool)
		if theError != kCVReturnSuccess {
			print("CVPixelBufferPoolCreate Failed")
		}
		
		let theError1 = CVPixelBufferPoolCreatePixelBuffer(nil, self.pixelBufferPool!, &pixelBuffer);
		if theError1 != kCVReturnSuccess {
			print("CVPixelBufferPoolCreatePixelBuffer Failed")
		}
		
		CVPixelBufferLockBaseAddress(pixelBuffer!, [])
		let bytePerRowY: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer!, 0)
		let bytesPerRowUV: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer!, 1)
		var base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer!, 0)
		if vf.frame!.data.0 != nil {
			memcpy(base, vf.frame!.data.0, bytePerRowY *  Int(vf.height))
		}
		base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer!, 1)
		if vf.frame!.data.1 != nil {
			memcpy(base, vf.frame!.data.1, bytesPerRowUV *  Int(vf.height) / 2)
		}
		CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
		return pixelBuffer!
	}
}

