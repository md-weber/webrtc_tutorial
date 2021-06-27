import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key, required this.title}) : super(key: key);
  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? pc;
  MediaStream? localStream;
  MediaStream? remoteStream;
  String? callId;
  late Future setup;

  @override
  void initState() {
    setup = setupPeerConnection();
    super.initState();
  }

  Future<void> setupPeerConnection() async {
    Map<String, dynamic> _iceServers = {
      'iceServers': [
        {'url': 'stun:stun.l.google.com:19302'},
      ],
    };

    final Map<String, dynamic> _config = {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ]
    };

    pc = await createPeerConnection({
      ..._iceServers,
      ...{'sdpSemantics': WebRTC.platformIsWindows ? 'plan-b' : 'unified-plan'},
    }, _config);
  }

  @override
  deactivate() {
    super.deactivate();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: RTCVideoView(_localRenderer, mirror: true)),
                SizedBox(width: 10),
                Expanded(child: RTCVideoView(_remoteRenderer, mirror: true)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () async {
                    await setup;
                    await _localRenderer.initialize();
                    await _remoteRenderer.initialize();

                    await createLocalStream();

                    var localTracks = localStream?.getTracks() ?? [];
                    for (final track in localTracks) {
                      pc?.addTrack(track);
                      print("Added Track");
                    }

                    pc?.onTrack = (event) {
                      print("Hello");
                      for (final track in event.streams[0].getTracks()) {
                        remoteStream?.addTrack(track);
                        print("Added Remote Track");
                      }
                    };
                    _remoteRenderer.srcObject = remoteStream;
                  },
                  icon: Icon(Icons.camera),
                ),
                IconButton(onPressed: initCall, icon: Icon(Icons.phone)),
                Column(
                  children: [
                    Text(callId ?? ""),
                    IconButton(
                      onPressed: () async {
                        await setup;

                        print(callId);
                        final callDoc = FirebaseFirestore.instance.collection('calls').doc(callId);
                        final answerCandidates = callDoc.collection('answerCandidates');
                        final offerCandidates = callDoc.collection('offerCandidates');

                        pc?.onIceCandidate = (event) {
                          print("onIceCandidate ${event.candidate}");
                          answerCandidates.add(event.toMap());
                        };

                        final callData = (await callDoc.get()).data();

                        print("Set Remote 1");
                        await pc?.setRemoteDescription(
                          RTCSessionDescription(callData?['sdp'], callData?['type']),
                        );

                        final answerDescription = await pc!.createAnswer();
                        await pc?.setLocalDescription(answerDescription);

                        final answer = answerDescription.toMap();

                        await callDoc.collection("answerCandidates").add(answer);

                        offerCandidates.snapshots().listen((snapshot) {
                          print("Hello World");

                          snapshot.docChanges.forEach((change) {
                            print(change);
                            if (change.type == DocumentChangeType.added) {
                              final data = change.doc.data();
                              pc?.addCandidate(
                                RTCIceCandidate(
                                  data?['candidate'],
                                  data?['sdpMid'],
                                  data?['sdpMlineIndex'],
                                ),
                              );
                            }
                          });
                        });
                      },
                      icon: Icon(Icons.add_link),
                    ),
                  ],
                )
              ],
            ),
          )
        ],
      ),
    );
  }

  void initCall() async {
    await setup;

    final callDoc = FirebaseFirestore.instance.collection('calls').doc();
    final offerCandidates = callDoc.collection('offerCandidates');
    final answerCandidates = callDoc.collection('answerCandidates');

    setState(() {
      callId = callDoc.id;
    });

    // Get candidates for caller, save to db
    pc?.onIceCandidate = (event) {
      print("onIceCandidate");
      callDoc.collection('offerCandidates').add(event.toMap());
    };

    // Create Offer
    final offerDescription = await pc?.createOffer();
    await pc?.setLocalDescription(offerDescription!);

    await callDoc.set(offerDescription?.toMap());

    // Listen for remote answer
    callDoc.snapshots().listen((snapshot) async {
      final data = snapshot.data();

      if (data == null) return;
      final remoteDescription = await pc?.getRemoteDescription();
      if (remoteDescription == null && data.containsValue('answer')) {
        final answerDescription = RTCSessionDescription(data['sdp'], data['type']);
        pc?.setRemoteDescription(answerDescription);
      }
    });

    answerCandidates.snapshots().listen((snapshot) async {
      print("Hello World 2 ");

      snapshot.docChanges.forEach((change) {
        print("Hello World 3 ${change.type} ");

        if (change.type == DocumentChangeType.added) {
          print(change);
          final candidate = RTCIceCandidate(
            change.doc.data()?['candidate'],
            change.doc.data()?['sdpMid'],
            change.doc.data()?['sdpMlineIndex'],
          );

          pc?.addCandidate(candidate);
        }
      });
    });
  }

  Future<void> createLocalStream() async {
    final Map<String, dynamic> mediaConstraints = {'audio': true, 'video': true};

    localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    _localRenderer.srcObject = localStream;
  }
}
