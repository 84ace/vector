import 'package:flutter/material.dart';
import '../../models/operator_profile.dart';
import '../../models/c2_message.dart';
import '../../crypto/e2ee_engine.dart';
import '../../crypto/mls_group_engine.dart';
import '../../services/mesh_client.dart';
import '../../services/p2p_mesh_engine.dart';
import '../theme/c2_colors.dart';

class ChatView extends StatefulWidget {
  final OperatorProfile myProfile;
  final List<OperatorProfile> teamProfiles;
  final List<C2Message> globalMessages;
  final OperatorProfile? activePeer;
  final int initialSubTabIndex;
  final MeshClient meshClient;
  final P2PMeshEngine p2pMeshEngine;
  final E2EEEngine cryptoEngine;
  final MLSGroupEngine mlsGroupEngine;
  final ValueChanged<C2Message> onMessageSent;
  final Function(String messageId, MessageStatus newStatus)? onUpdateStatus;

  const ChatView({
    super.key,
    required this.myProfile,
    required this.teamProfiles,
    required this.globalMessages,
    this.activePeer,
    this.initialSubTabIndex = 0,
    required this.meshClient,
    required this.p2pMeshEngine,
    required this.cryptoEngine,
    required this.mlsGroupEngine,
    required this.onMessageSent,
    this.onUpdateStatus,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _inputController = TextEditingController();

  final ScrollController _singleScrollController = ScrollController();
  final ScrollController _groupScrollController = ScrollController();
  final ScrollController _broadcastScrollController = ScrollController();

  OperatorProfile? _selectedPeer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialSubTabIndex,
    );

    _selectedPeer = widget.activePeer;
    if (_selectedPeer == null) {
      final selectable = widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();
      if (selectable.isNotEmpty) {
        _selectedPeer = selectable.first;
      }
    }
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSubTabIndex != widget.initialSubTabIndex) {
      _tabController.animateTo(widget.initialSubTabIndex);
    }
    if (widget.activePeer != null && widget.activePeer!.id != _selectedPeer?.id) {
      setState(() {
        _selectedPeer = widget.activePeer;
        _tabController.animateTo(0);
      });
      _scrollToBottom();
    } else if (_selectedPeer == null) {
      final selectable = widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();
      if (selectable.isNotEmpty) {
        setState(() {
          _selectedPeer = selectable.first;
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScrollController? activeCtrl;
      switch (_tabController.index) {
        case 0:
          activeCtrl = _singleScrollController;
          break;
        case 1:
          activeCtrl = _groupScrollController;
          break;
        case 2:
          activeCtrl = _broadcastScrollController;
          break;
      }

      if (activeCtrl != null && activeCtrl.hasClients && activeCtrl.position.hasContentDimensions) {
        activeCtrl.animateTo(
          activeCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _inputController.dispose();
    _singleScrollController.dispose();
    _groupScrollController.dispose();
    _broadcastScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.lock, color: C2Colors.emeraldAccent, size: 18),
            SizedBox(width: 8),
            Text(
              'TACTICAL SECURE COMMS',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyanAccent,
          labelColor: Colors.cyanAccent,
          unselectedLabelColor: Colors.white54,
          labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'DIRECT CHAT'),
            Tab(text: 'SQUAD CHAT'),
            Tab(text: 'BROADCAST'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _build1to1ChatTab(),
          _buildGroupChatTab(),
          _buildBroadcastTab(),
        ],
      ),
    );
  }

  Widget _build1to1ChatTab() {
    final selectablePeers = widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();

    if (selectablePeers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.person_add_disabled, color: Colors.white38, size: 48),
              const SizedBox(height: 16),
              const Text(
                'NO PAIRED SQUAD CONTACTS YET',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Go to the "Pairing" tab to scan or share your pairing code with a team member.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Security Status Badge
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          color: C2Colors.emeraldAccent.withOpacity(0.15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.verified, color: C2Colors.emeraldAccent, size: 12),
              const SizedBox(width: 6),
              Text(
                'Encrypted chat with ${_selectedPeer?.callsign ?? "Target"}',
                style: const TextStyle(color: C2Colors.emeraldAccent, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),

        // Peer selector horizontal chips
        Container(
          height: 50,
          color: const Color(0xFF0F172A),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: selectablePeers.length,
            itemBuilder: (context, index) {
              final peer = selectablePeers[index];
              final isSelected = _selectedPeer?.id == peer.id;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: FilterChip(
                  selected: isSelected,
                  selectedColor: Colors.cyan.withOpacity(0.2),
                  checkmarkColor: Colors.cyanAccent,
                  backgroundColor: const Color(0xFF1E293B),
                  label: Text(
                    peer.callsign,
                    style: TextStyle(
                      color: isSelected ? Colors.cyanAccent : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onSelected: (_) {
                    setState(() {
                      _selectedPeer = peer;
                    });
                    _scrollToBottom();
                  },
                ),
              );
            },
          ),
        ),
        const Divider(color: Colors.white12, height: 1),

        // Message List
        Expanded(
          child: _buildMessageList(MessageType.chat1to1, _singleScrollController),
        ),

        // Message Input Bar
        _buildInputBar(MessageType.chat1to1),
      ],
    );
  }

  Widget _buildGroupChatTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          color: const Color(0xFF1E293B).withOpacity(0.5),
          child: Row(
            children: [
              const Icon(Icons.groups, color: Colors.cyanAccent, size: 18),
              const SizedBox(width: 8),
              Text(
                'SQUAD: ${widget.mlsGroupEngine.groupName.toUpperCase()} (${widget.mlsGroupEngine.memberPublicKeys.length} MEMBERS)',
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        Expanded(child: _buildMessageList(MessageType.chatGroup, _groupScrollController)),
        _buildInputBar(MessageType.chatGroup),
      ],
    );
  }

  Widget _buildBroadcastTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          color: Colors.amber.withOpacity(0.15),
          child: const Row(
            children: [
              Icon(Icons.campaign, color: Colors.amberAccent, size: 18),
              SizedBox(width: 8),
              Text(
                'OPERATIONAL BROADCAST CHANNEL (ALL TEAM MEMBERS)',
                style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        Expanded(child: _buildMessageList(MessageType.broadcast, _broadcastScrollController)),
        _buildInputBar(MessageType.broadcast),
      ],
    );
  }

  Widget _buildMessageList(MessageType typeFilter, ScrollController controller) {
    List<C2Message> filtered;

    if (typeFilter == MessageType.chat1to1) {
      if (_selectedPeer == null) return const SizedBox.shrink();
      filtered = widget.globalMessages.where((m) {
        return m.type == MessageType.chat1to1 &&
            ((m.senderId == widget.myProfile.id && m.recipientId == _selectedPeer!.id) ||
             (m.senderId == _selectedPeer!.id && m.recipientId == widget.myProfile.id));
      }).toList();
    } else if (typeFilter == MessageType.broadcast) {
      filtered = widget.globalMessages.where((m) {
        return m.type == MessageType.broadcast &&
            !m.encryptedBody.contains('DELIVERY_ACK') &&
            !m.encryptedBody.contains('READ_ACK') &&
            !m.encryptedBody.contains('UNPAIR_AND_PURGE') &&
            !m.encryptedBody.contains('PAIR_REQUEST');
      }).toList();
    } else {
      filtered = widget.globalMessages.where((m) => m.type == typeFilter).toList();
    }

    if (filtered.isEmpty) {
      return const Center(
        child: Text(
          'No message history yet.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(12),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final msg = filtered[index];
        final isMe = msg.senderId == widget.myProfile.id;

        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFF0284C7) : const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isMe ? Colors.cyanAccent.withOpacity(0.4) : Colors.white12,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMe) ...[
                  Text(
                    msg.senderId.toUpperCase(),
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  msg.decryptedBody ?? 'Decryption Failed',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock, color: Colors.white38, size: 10),
                    const SizedBox(width: 4),
                    Text(
                      '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white38, fontSize: 9),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      _buildStatusIndicator(msg.status),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusIndicator(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white54),
        );
      case MessageStatus.sent:
        return const Icon(Icons.check, color: Colors.white54, size: 12);
      case MessageStatus.delivered:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, color: Colors.white70, size: 12),
          ],
        );
      case MessageStatus.read:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, color: Colors.cyanAccent, size: 12),
          ],
        );
    }
  }

  Widget _buildInputBar(MessageType type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF1E293B),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Type a message...',
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _sendMessage(type),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: const BoxDecoration(
              color: Colors.cyanAccent,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.black, size: 18),
              onPressed: () => _sendMessage(type),
            ),
          ),
        ],
      ),
    );
  }

  void _sendMessage(MessageType type) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    String cipherText = '';
    String? recipientId;

    if (type == MessageType.chat1to1) {
      if (_selectedPeer == null) return;
      recipientId = _selectedPeer!.id;
      cipherText = widget.cryptoEngine.encryptPayload(text, _selectedPeer!.publicKey);
    } else if (type == MessageType.chatGroup || type == MessageType.broadcast) {
      cipherText = widget.mlsGroupEngine.encryptGroupMessage(text);
    }

    final msg = C2Message(
      id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      senderId: widget.myProfile.id,
      senderPublicKey: widget.myProfile.publicKey,
      recipientId: recipientId,
      groupId: widget.mlsGroupEngine.groupId,
      encryptedBody: cipherText,
      decryptedBody: text,
      timestamp: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
    );

    widget.meshClient.sendMessage(msg);
    widget.p2pMeshEngine.sendP2PDirectMessage(msg);
    widget.onMessageSent(msg);

    setState(() {
      _inputController.clear();
    });
    _scrollToBottom();
  }
}
