import React, { useRef, useState } from 'react';
import {
  SafeAreaView, View, Text, Pressable, TextInput,
  PanResponder, Animated, StyleSheet,
} from 'react-native';

// Wand React Native showcase. Mirrors the native one: every interactive view has
// a testID (→ iOS accessibilityIdentifier), and the last recognized gesture is
// written into the `#status` element so Wand can verify gestures via the
// accessibility tree alone. Pure React Native (PanResponder) — no extra native deps.
export default function App() {
  const [status, setStatus] = useState('ready');
  const [taps, setTaps] = useState(0);
  const [typed, setTyped] = useState('');
  const [dropped, setDropped] = useState('');

  // --- Pinch (two-finger distance) ---
  const pinchStart = useRef(null);
  const pinch = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderMove: (e) => {
        const t = e.nativeEvent.touches;
        if (t.length >= 2) {
          const d = Math.hypot(t[0].pageX - t[1].pageX, t[0].pageY - t[1].pageY);
          if (pinchStart.current == null) pinchStart.current = d;
          setStatus('pinch:' + (d / pinchStart.current).toFixed(2));
        }
      },
      onPanResponderRelease: () => {
        if (pinchStart.current != null) setStatus((s) => s.replace('pinch:', 'pinched:'));
        pinchStart.current = null;
      },
    })
  ).current;

  // --- Rotate (two-finger angle) ---
  const rotStart = useRef(null);
  const rotate = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderMove: (e) => {
        const t = e.nativeEvent.touches;
        if (t.length >= 2) {
          const a = Math.atan2(t[0].pageY - t[1].pageY, t[0].pageX - t[1].pageX);
          if (rotStart.current == null) rotStart.current = a;
          const deg = Math.round(((a - rotStart.current) * 180) / Math.PI);
          setStatus('rotate:' + deg);
        }
      },
      onPanResponderRelease: () => {
        if (rotStart.current != null) setStatus((s) => s.replace('rotate:', 'rotated:'));
        rotStart.current = null;
      },
    })
  ).current;

  // --- Drag & drop ---
  const pan = useRef(new Animated.ValueXY()).current;
  const drag = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderMove: (e, g) => {
        pan.setValue({ x: g.dx, y: g.dy });
        setStatus('drag:' + Math.round(g.moveX) + ',' + Math.round(g.moveY));
      },
      onPanResponderRelease: (e, g) => {
        const zone = g.moveX > 200 ? 'zoneB' : 'zoneA';
        setDropped(zone);
        setStatus('drop:' + zone);
        // Keep the circle where it was dropped (don't snap back to origin).
      },
    })
  ).current;

  return (
    <SafeAreaView style={s.root}>
      <View testID="status" accessible accessibilityLabel={status} style={s.status}>
        <Text style={s.statusText}>{status}</Text>
      </View>

      <View style={s.row}>
        <View style={s.card}>
          <Text style={s.title}>Tap</Text>
          <Pressable
            testID="tapButton"
            style={s.btn}
            onPress={() => { const n = taps + 1; setTaps(n); setStatus('tap:' + n); }}>
            <Text style={s.btnText}>Tap me</Text>
          </Pressable>
          <Text testID="tapCount" style={s.caption}>count: {taps}</Text>
        </View>

        <View style={s.card}>
          <Text style={s.title}>Long press</Text>
          <Pressable
            testID="longPressBox"
            delayLongPress={500}
            onLongPress={() => setStatus('longpress')}
            style={[s.box, { backgroundColor: '#9aa' }]}>
            <Text style={s.btnText}>hold me</Text>
          </Pressable>
        </View>
      </View>

      <View style={s.row}>
        <View style={s.card}>
          <Text style={s.title}>Pinch / Zoom</Text>
          <View testID="pinchBox" accessible {...pinch.panHandlers} style={[s.box, { backgroundColor: '#e8943a', height: 110 }]} />
        </View>
        <View style={s.card}>
          <Text style={s.title}>Rotate</Text>
          <View testID="rotateBox" accessible {...rotate.panHandlers} style={[s.box, { backgroundColor: '#7b54c4', height: 110 }]} />
        </View>
      </View>

      <View style={s.card}>
        <Text style={s.title}>Drag &amp; drop (drag red circle onto A or B)</Text>
        <View style={s.dragArea}>
          <View testID="zoneA" accessible accessibilityLabel="A" style={[s.zone, { left: 70 }, dropped === 'zoneA' && s.zoneActive]}><Text>A</Text></View>
          <View testID="zoneB" accessible accessibilityLabel="B" style={[s.zone, { left: 220 }, dropped === 'zoneB' && s.zoneActive]}><Text>B</Text></View>
          <Animated.View
            testID="dragHandle"
            accessible
            {...drag.panHandlers}
            style={[s.handle, { transform: pan.getTranslateTransform() }]}>
            <Text style={s.btnText}>drag</Text>
          </Animated.View>
        </View>
        <Text testID="dropResult" style={s.caption}>{dropped ? 'dropped on ' + dropped : '—'}</Text>
      </View>

      <View style={s.card}>
        <Text style={s.title}>Text entry</Text>
        <TextInput
          testID="textInput"
          placeholder="type here"
          autoCapitalize="none"
          autoCorrect={false}
          value={typed}
          onChangeText={(t) => { setTyped(t); setStatus('typed:' + t); }}
          style={s.input}
        />
      </View>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#fff', paddingHorizontal: 8 },
  status: { backgroundColor: '#000', padding: 12 },
  statusText: { color: '#fff', textAlign: 'center', fontWeight: '600', fontFamily: 'Menlo' },
  row: { flexDirection: 'row', gap: 8, marginTop: 8 },
  card: { flex: 1, backgroundColor: '#f2f2f2', borderRadius: 12, padding: 10, marginTop: 8 },
  title: { fontSize: 12, color: '#666', marginBottom: 6 },
  caption: { fontSize: 12, marginTop: 6 },
  btn: { backgroundColor: '#2a6df4', borderRadius: 8, paddingVertical: 14, alignItems: 'center' },
  btnText: { color: '#fff', fontWeight: '600' },
  box: { height: 56, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  dragArea: { height: 90, justifyContent: 'center' },
  zone: { position: 'absolute', width: 72, height: 72, borderWidth: 2, borderColor: '#2a6df4', borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  zoneActive: { borderColor: '#22a559', backgroundColor: 'rgba(34,165,89,0.2)' },
  handle: { width: 60, height: 60, borderRadius: 30, backgroundColor: 'red', alignItems: 'center', justifyContent: 'center' },
  input: { borderWidth: 1, borderColor: '#bbb', borderRadius: 8, padding: 10 },
});
