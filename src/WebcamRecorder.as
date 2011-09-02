package
{
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.NetStatusEvent;
	import flash.external.ExternalInterface;
	import flash.media.Camera;
	import flash.media.Microphone;
	import flash.media.Video;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.system.Security;
	import flash.utils.clearTimeout;
	import flash.utils.setTimeout;
	
	import mx.core.FlexGlobals;

	/**
	 * WebcamRecorder uses the user's webcam and/or microphone to record
	 * video and/or audio and stream it to a Wowza server which then stores
	 * it. It can play the recorded video or sound, and send notifications
	 * about its state to a provided Javascript listener.
	 * 
	 * @see flash.media.Camera
	 * @see flash.media.Microphone
	 * @see flash.media.Video
	 * @see flash.net.NetConnection
	 * @see flash.net.NetStream
	 */
	public class WebcamRecorder extends EventDispatcher
	{
		//------------------------------------//
		//									  //
		//				CONSTS				  //
		//									  //
		//------------------------------------//
		
		/** Recording mode using the webcam to record video and the microphone to record audio */
		public static const VIDEO : String = "video";
		
		/** Recording mode using the microphone to record audio */
		public static const AUDIO : String = "audio";
		
		/** The Wowza server URL */
		private static const SERVER_URL : String = "rtmp://localhost/WebcamRecorder";
		
		/** Video width (in pixels) */
		private static const VIDEO_WIDTH : uint = 160;
		
		/** Video height (in pixels) */
		private static const VIDEO_HEIGHT : uint = 120;
		
		
		//------------------------------------//
		//									  //
		//				VARS				  //
		//									  //
		//------------------------------------//
		
		private var _recordingMode : String;
		private var _serverConnection : NetConnection;
		private var _jsListener : String;
		private var _notificationTimer : uint;
		private var _videoPreview : Video;
		private var _webcam : Camera;
		private var _microphone : Microphone;
		private var _publishStream : NetStream;
		private var _playStream : NetStream;
		private var _currentRecordId : String;
		private var _previousRecordId : String;
		private var _flushBufferTimer : uint;
		
		
		
		//------------------------------------//
		//									  //
		//				PUBLIC API			  //
		//									  //
		//------------------------------------//
		
		/** Constructor: Try to connect to the server */
		public function WebcamRecorder()
		{
			// Connect to the server
			_serverConnection = new NetConnection();
			_serverConnection.addEventListener( NetStatusEvent.NET_STATUS, onConnectionStatus );
			_serverConnection.connect( SERVER_URL );
		}
		
		/**
		 * Initialize the recorder.
		 * 
		 * @param recordingMode String: Can be either WebcamRecorder.VIDEO or WebcamRecorder.AUDIO.
		 * Note that WebcamRecorder.VIDEO includes audio recording if a microphone is available.
		 * 
		 * @param jsListener String: The name of a Javascript listener function able to handle our
		 * notifications. It has to conform to the following API: TO DO.
		 * 
		 * @param notificationFrequency Number: The frequency at which the recorder will send notifications
		 * to the JS listener (in Hz).
		 */
		public function init( recordingMode:String, jsListener:String, notificationFrequency:Number ):void
		{
			// The recorder can be initialized only once
			if( _recordingMode )
			{
				log( 'error', 'init - Recorder already initialized!' );
				return;
			}
			
			// Check the recording mode
			if( !( recordingMode == VIDEO || recordingMode == AUDIO ) )
			{
				log( 'error', 'init - recordingMode should be either ' + VIDEO + ' or ' + AUDIO + '(given: ' + recordingMode + ')' );
				return;
			}
			
			// Set up the recording
			_recordingMode = recordingMode;
			if( recordingMode == VIDEO )
			{
				_videoPreview = new Video( VIDEO_WIDTH, VIDEO_HEIGHT );
				FlexGlobals.topLevelApplication.stage.addChild( _videoPreview );
			}
			setUpRecording();
			
			// Set up the JS notifications
			setUpJSNotifications( jsListener, notificationFrequency );
		}
		
		public function record( recordId:String ):void
		{
			if( !recordId || recordId.length == 0 )
			{
				log( 'error', 'record - recordId must be a non-empty string' );
				return;
			}
			
			// If there is a playback in progress, we stop it and connect the preview video to the webcam
			if( _playStream )
			{
				log( 'info', 'record - Stopped playback to record' );
				stopPlayStream();
				setUpRecording();
			}
			
			_currentRecordId = recordId;
			startPublishStream( recordId, false );
		}
		
		/** Stop the current recording without the possibility to resume it. */
		public function stopRecording():void
		{
			if( !_publishStream && !_currentRecordId )
			{
				log( 'error', 'stopRecording - No recording started!' );
				return;
			}
			
			if( _publishStream )
				stopPublishStream();
			
			_previousRecordId = _currentRecordId;
			_currentRecordId = null;
		}
		
		/**
		 * Stop the current recording with the possibility to resume it.
		 * 
		 * @see #resumeRecording()
		 */
		public function pauseRecording():void
		{
			if( !_publishStream )
			{
				log( 'error', 'pauseRecording - Not recording!' );
				return;
			}
			
			stopPublishStream();
		}
		
		/**
		 * Resume the previously paused recording.
		 * 
		 * @see #pauseRecording()
		 */
		public function resumeRecording():void
		{
			if( !_currentRecordId )
			{
				log( 'error', 'resumeRecording - No recording started!' );
				return;
			}
			
			startPublishStream( _currentRecordId, true );
		}
		
		/**
		 * Play the previous recording. You have to call <code>stopRecording()</code>
		 * before being able to call <code>play()</code>.
		 * 
		 * @see #stopRecording()
		 */
		public function play():void
		{
			// If we already started playing, we just resume
			if( _playStream )
			{
				_playStream.resume();
				return;
			}
			
			if( _publishStream )
			{
				log( 'error', 'play - Currently recording. You have to call stopRecording() before play().' );
				return;
			}
			
			if( !_previousRecordId )
			{
				log( 'error', 'play - Nothing recorded yet. You have to call stopRecording() before play().' );
				return;
			}
			
			startPlayStream( _previousRecordId );
		}
		
		public function seek( time:Number ):void
		{
			return;
		}
		
		/** Pause the current playback */
		public function pausePlaying():void
		{
			if( !_playStream )
			{
				log( 'error', 'pausePlaying - Not playing anything!' );
				return;
			}
			
			_playStream.pause();
		}
		
		
		//------------------------------------//
		//									  //
		//			PRIVATE METHODS			  //
		//									  //
		//------------------------------------//
		
		/** Set up the JS API */
		private function setUpJSApi():void
		{
			if( !ExternalInterface.available )
			{
				log( 'warn', 'setUpJSApi - ExternalInterface not available: the Flex component won\'t be reachable from Javascript!');
				return;
			}
			
			Security.allowDomain('*');
			ExternalInterface.addCallback( 'init', init );
			ExternalInterface.addCallback( 'record', record );
			ExternalInterface.addCallback( 'pauseRecording', pauseRecording );
			ExternalInterface.addCallback( 'stopRecording', stopRecording );
			ExternalInterface.addCallback( 'resumeRecording', resumeRecording );
			ExternalInterface.addCallback( 'play', play );
			ExternalInterface.addCallback( 'seek', seek );
			ExternalInterface.addCallback( 'pausePlaying', pausePlaying );
			log( 'info', 'JS API initialized' );
		}
		
		/** Set up the JS notifications */
		private function setUpJSNotifications( jsListener:String, notificationFrequency:Number ):void
		{
			// Check the notification frequency
			if( !( notificationFrequency >= 0 ) )
				log( 'warn', 'init - notificationFrequency has to be greater or equal to zero! We won\' notify for this session.' );
			
			// Set up the notifications
			_jsListener = jsListener;
			_notificationTimer = setTimeout( notify, 1/(notificationFrequency*1000) );
		}
		
		/** Trace a log message and forward it to the Javascript console */
		private function log( level:String, msg:String ):void
		{
			trace( level.toLocaleUpperCase() + ' :: ' + msg );
			if( ExternalInterface.available )
				ExternalInterface.call( 'console.'+level, msg );
		}
		
		/** Trigger the sending of a notification to the JS listener */
		private function notify():void
		{
			return;
		}
		
		/**
		 * Listen to the server connection status. Set up the JS API
		 * if the connection was successful.
		 */
		private function onConnectionStatus( event:NetStatusEvent ):void
		{
			if( event.info.code == "NetConnection.Connect.Success" )
				setUpJSApi();
			else if( event.info.code == "NetConnection.Connect.Failed" || event.info.code == "NetConnection.Connect.Rejected" )
				log( 'error', 'Connection error: ' + event.info.description );
		}
		
		/** Set up the recording device(s) (webcam and/or microphone) */
		private function setUpRecording():void
		{
			// Video (if necessary)
			if( _recordingMode == VIDEO )
			{
				if( !_webcam )
				{
					_webcam = Camera.getCamera();
					_webcam.setMode( VIDEO_WIDTH, VIDEO_HEIGHT, 30, false );
					_webcam.setQuality( 0, 88 );
					_webcam.setKeyFrameInterval( 30 );
				}
				
				_videoPreview.attachNetStream( null );
				_videoPreview.attachCamera( _webcam );
			}
			
			// Audio
			if( !_microphone )
			{
				_microphone = Microphone.getMicrophone();
				_microphone.rate = 11;
			}
		}
		
		/**
		 * Start the publish stream.
		 * 
		 * @param recordId String: The name of the recorded file.
		 * @param append Boolean: true if we resume an existing recording, false otherwise.
		 */
		private function startPublishStream( recordId:String, append:Boolean ):void
		{
			// Set up the publish stream
			_publishStream = new NetStream( _serverConnection );
			_publishStream.client = {};
			
			// Start the recording
			_publishStream.publish( recordId, append?"append":"record" );
			
			// Attach the devices
			_publishStream.attachCamera( _webcam );
			_publishStream.attachAudio( _microphone );
			
			// Set the buffer
			_publishStream.bufferTime = 20;
		}
		
		/** Stop the publish stream or monitor the buffer size */
		private function stopPublishStream():void
		{
			// Detach the devices
			_publishStream.attachCamera( null );
			_publishStream.attachAudio( null );
			
			// Stop the recording or delay if the buffer is not empty
			if( _publishStream.bufferLength == 0 )
				doStopPublishStream();
			else
				_flushBufferTimer = setTimeout( checkBufferLength, 250 );
		}
		
		/** Check the buffer length and stop the publish stream if empty */
		private function checkBufferLength():void
		{
			if( _publishStream.bufferLength > 0 )
				return;
			
			clearTimeout( _flushBufferTimer );
			_flushBufferTimer = 0;
			doStopPublishStream();
		}
		
		/** Actually stop the publish stream */
		private function doStopPublishStream():void
		{
			_publishStream.publish( null );
			_publishStream = null;
		}
		
		/** Stop the play stream */
		private function stopPlayStream():void
		{
			_playStream.pause();
			_playStream = null;
		}
		
		/**
		 * Start the play stream.
		 * 
		 * @param playId String: The name of the file to play.
		 */
		private function startPlayStream( playId:String ):void
		{
			// Set up the play stream
			_playStream = new NetStream( _serverConnection );
			_playStream.client = {};
			_playStream.bufferTime = 2;
			
			// Replace the webcam preview by the stream playback
			setUpPlaying();
			
			// Start the playback
			_playStream.play( _previousRecordId );
		}
		
		/** Set up the player */
		private function setUpPlaying():void
		{
			_videoPreview.attachCamera( null );
			_videoPreview.attachNetStream( _playStream );
		}
	}
}