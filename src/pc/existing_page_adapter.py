"""Call from an EXISTING UDP service; never opens sockets or starts a webpage."""
from radar_protocol import decode, ReceiverState, LABELS, NAMES


class ExistingPageAdapter:
    def __init__(self, board_ip='192.168.1.10'):
        self.board_ip = board_ip
        self.receiver = ReceiverState()

    def ingest(self, data, peer_ip, now=None):
        """Return one UI update, or None for other sources/duplicates/old data.

        Invalid v3 packets raise ValueError/TypeError/UnicodeError: log and skip
        in the existing service. Call on its receive thread, then dispatch the
        returned dict through its existing WebSocket/SSE/API state mechanism.
        """
        if peer_ip != self.board_ip:
            return None
        message = decode(data)
        if message['origin'] != 'board':
            return None
        changed_session = self.receiver.session != (message['origin'], message['session'])
        accepted, _ = self.receiver.ingest(message, now)
        if not accepted:
            return None
        common = dict(kind=message['kind'], session=message['session'],
                      seq=message['seq'], t_us=message['t_us'],
                      reset_other_stream=changed_session)
        if message['kind'] == 'doa':
            # Current board sends MVDR only. Never substitute DAS into the UI.
            valid = message['valid'] and message['method'] == 'mvdr'
            return dict(common, valid=valid, signal=message['signal'],
                        method=message['method'],
                        angle_deg=message['azimuth_mdeg']/1000 if valid else None)
        state = message['state']
        display = NAMES[LABELS.index(message['label'])] if state == 'event' else {
            'background':'安静', 'uncertain':'不确定',
            'pending':'等待音频窗口', 'error':'采集/识别已停止'}[state]
        return dict(common, state=state, label=message['label'], display_name=display,
                    confidence_pct=message['confidence_ppm']/10000 if state == 'event' else None,
                    scores=[dict(label=key, name_zh=NAMES[i], score_pct=value/10000)
                            for i,(key,value) in enumerate(zip(LABELS,message['scores_ppm']))]
                           if state != 'background' else [],
                    model_seq=message['model_seq'], audio_gaps=message['audio_gaps'],
                    missed_windows=message['missed_windows'])

    def stale(self, kind, now=None):
        """Use the existing backend timer to clear old data after 2 seconds."""
        return self.receiver.stale(kind, now)
