import { StatusBar } from 'expo-status-bar';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Alert,
  Animated,
  DynamicColorIOS,
  Easing,
  Linking,
  Modal,
  NativeEventEmitter,
  NativeModules,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  useColorScheme,
  View,
} from 'react-native';

const nativeApp = NativeModules.ElevenLabsNative;
const emptyState = {
  phase: 'idle',
  errorText: null,
  transcriptText: '',
  language: { rawValue: 'automatic', title: 'Auto' },
  languages: [],
  cleanSpeech: true,
  autoCopy: true,
  hasAPIKey: false,
  needsMicrophoneSettings: false,
  recordingNotice: null,
  isPreparingKeyboardSession: false,
  isKeyboardDictation: false,
  hasRecoverableRecording: false,
  duration: 0,
  level: 0,
  completedOnboarding: false,
  practicedControlCenterStart: false,
  keyboardSetupDetected: false,
  keyboardFullAccess: false,
  history: [],
  historyRetention: 'forever',
  // This object is used only for bridge-failure fallbacks. Let those errors
  // render; successful launches receive the authoritative gate from native.
  launchStateReady: true,
};

const retentionLabels = {
  never: 'Never',
  oneDay: '1 Day',
  sevenDays: '7 Days',
  thirtyDays: '30 Days',
  ninetyDays: '90 Days',
  forever: 'Forever',
};

function Button({ children, destructive = false, disabled = false, onPress, secondary = false, small = false }) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        secondary && styles.buttonSecondary,
        destructive && styles.buttonDestructive,
        small && styles.buttonSmall,
        disabled && styles.disabled,
        pressed && !disabled && styles.pressed,
      ]}
    >
      <Text style={[styles.buttonLabel, secondary && styles.buttonSecondaryLabel, destructive && styles.buttonDestructiveLabel]}>
        {children}
      </Text>
    </Pressable>
  );
}

function Header({ onClose, title }) {
  return (
    <View style={styles.sheetHeader}>
      <Text style={styles.sheetTitle}>{title}</Text>
      <Pressable accessibilityLabel={`Close ${title}`} accessibilityRole="button" onPress={onClose} style={styles.closeButton}>
        <Text style={styles.closeButtonLabel}>Done</Text>
      </Pressable>
    </View>
  );
}

const privacyURL = 'https://pedro-antonio.pedroavj.chatgpt.site/dictation/privacy/';
const supportURL = 'https://pedro-antonio.pedroavj.chatgpt.site/dictation/support/';

function Onboarding({ state, update, openSettings }) {
  if (!state.hasAPIKey) {
    return (
      <View style={styles.centeredPage}>
        <View style={styles.iconTile}><Text style={styles.waveIcon}>≋</Text></View>
        <Text style={styles.largeTitle}>Your voice. Your API key.</Text>
        <Text style={styles.bodyCenter}>
          Dictation Button uses your own ElevenLabs API key. Audio is sent directly to ElevenLabs for transcription, including live drafts while you record. ElevenLabs usage is charged to your account.
        </Text>
        <View style={styles.fullWidthActions}>
          <Button onPress={openSettings}>Add API key</Button>
          <Button onPress={() => Linking.openURL(privacyURL)} secondary>Privacy</Button>
        </View>
      </View>
    );
  }
  if (!state.practicedControlCenterStart) {
    return (
      <View style={styles.centeredPage}>
        <View style={styles.iconTile}><Text style={styles.waveIcon}>≋</Text></View>
        <Text style={styles.largeTitle}>Start once from Control Center.</Text>
        <Text style={styles.bodyCenter}>
          Open Control Center, touch and hold, tap Add a Control, then choose Dictation Button.
        </Text>
        <Text style={styles.captionCenter}>Tap the control to show the Live Activity, then tap Start on the activity. Setup advances when recording starts.</Text>
        <Button onPress={openSettings} secondary small>Settings</Button>
      </View>
    );
  }

  const needsFullAccess = state.keyboardSetupDetected && !state.keyboardFullAccess;
  return (
    <View style={styles.centeredPage}>
      <View style={styles.sendCircle}><Text style={styles.sendGlyph}>➤</Text></View>
      <Text style={styles.largeTitle}>{needsFullAccess ? 'Allow Full Access.' : 'Add the Dictation Button keyboard.'}</Text>
      <Text style={styles.bodyCenter}>
        {needsFullAccess
          ? 'In Keyboard Settings, open Dictation Button and turn on Allow Full Access.'
          : 'In Keyboard Settings, add Dictation Button and turn on Allow Full Access.'}
      </Text>
      <View style={styles.fullWidthActions}>
        <Button onPress={() => update('openKeyboardSettings')}>Open Keyboard Settings</Button>
      </View>
      <Text style={styles.captionCenter}>Select Dictation Button once in any text field. Setup finishes automatically—there is no Done step.</Text>
    </View>
  );
}

function useReducedMotion() {
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    let active = true;
    AccessibilityInfo.isReduceMotionEnabled().then((value) => {
      if (active) setReduced(value);
    });
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduced);
    return () => {
      active = false;
      subscription?.remove?.();
    };
  }, []);

  return reduced;
}

function Waveform({ frozen = false, level = 0, mode = 'recording' }) {
  const reduceMotion = useReducedMotion();
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    if (frozen || reduceMotion) return undefined;
    const interval = setInterval(() => setFrame((value) => (value + 1) % 240), 90);
    return () => clearInterval(interval);
  }, [frozen, reduceMotion]);

  const heights = useMemo(
    () => {
      const count = 22;
      const gatedLevel = Math.max(0, Math.min(1, ((level || 0) - 0.018) / 0.28));
      const voiceEnergy = Math.pow(gatedLevel, 0.42);

      return Array.from({ length: count }, (_, index) => {
        const motion = 0.24 + 0.76 * Math.abs(
          Math.sin(frame * 0.78 - index * 0.61) * Math.cos(frame * 0.31 + index * 0.37)
        );
        const distance = Math.abs(index - (count - 1) / 2) / Math.max(1, (count - 1) / 2);
        const contour = 1 - 0.24 * distance;

        if (mode === 'starting') return 12 + 82 * (0.28 + 0.72 * motion) * contour;

        return 4 + 155 * voiceEnergy * (0.34 + 0.66 * motion) * contour;
      });
    },
    [frame, frozen, level, mode]
  );

  return (
    <View style={styles.waveform}>
      {heights.map((height, index) => (
        <View
          key={index}
          style={[styles.waveColumn, { height }]}
        >
          <View
            style={[
              styles.waveBar,
              frozen && styles.waveBarFrozen,
              { height },
            ]}
          />
          {frozen ? <View style={styles.wavePeakCap} /> : null}
        </View>
      ))}
    </View>
  );
}

function SwipeBackCue({ paused }) {
  const reduceMotion = useReducedMotion();
  const travel = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (reduceMotion) {
      travel.setValue(0.5);
      return undefined;
    }
    const animation = Animated.loop(
      Animated.sequence([
        Animated.timing(travel, {
          duration: 720,
          easing: Easing.inOut(Easing.cubic),
          toValue: 1,
          useNativeDriver: true,
        }),
        Animated.timing(travel, {
          duration: 720,
          easing: Easing.inOut(Easing.cubic),
          toValue: 0,
          useNativeDriver: true,
        }),
      ])
    );
    animation.start();
    return () => animation.stop();
  }, [reduceMotion, travel]);

  return (
    <View
      accessibilityLabel={paused ? 'Swipe back. Listening is paused.' : 'Swipe back. Recording continues.'}
      accessible
      style={styles.swipeCue}
    >
      <Text style={[styles.swipeCueTitle, paused && styles.pausedInk]}>Swipe back</Text>
      <View style={[styles.swipeTrack, paused && styles.swipeTrackPaused]}>
        <Animated.View
          style={[
            styles.swipeThumb,
            paused && styles.swipeThumbPaused,
            { transform: [{ translateX: travel.interpolate({ inputRange: [0, 1], outputRange: [0, 82] }) }] },
          ]}
        />
      </View>
    </View>
  );
}

function formatDuration(value) {
  const seconds = Math.max(0, Math.floor(value || 0));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function Session({ state }) {
  const starting = state.isPreparingKeyboardSession && state.phase === 'idle';
  const sending = state.phase === 'transcribing';
  const paused = state.phase === 'paused';
  const status = starting ? 'Starting' : sending ? 'Transcribing' : paused ? 'Paused' : 'Recording';
  return (
    <View style={[styles.sessionPage, paused && styles.sessionPagePaused]}>
      <View style={styles.sessionStatus}>
        <Text style={[styles.sessionStatusText, paused && styles.pausedInk]}>{status}</Text>
        {(!starting && !sending) ? (
          <>
            <Text style={[styles.statusSeparator, paused && styles.statusSeparatorPaused]}>·</Text>
            <Text style={[styles.sessionDuration, paused && styles.pausedInk]}>{formatDuration(state.duration)}</Text>
          </>
        ) : null}
      </View>
      <View style={styles.sessionCenter}>
        {sending ? (
          <>
            <ActivityIndicator
              accessibilityLabel="Transcribing dictation"
              color="#ffffff"
              size="large"
              style={styles.processingSpinner}
            />
            <Text style={styles.processingTitle}>Turning voice into text.</Text>
          </>
        ) : starting ? (
          <Waveform mode="starting" />
        ) : paused ? (
          <Waveform frozen level={state.level} />
        ) : (
          <Waveform level={state.level} />
        )}
      </View>
      {(!starting && !sending) ? <SwipeBackCue paused={paused} /> : null}
    </View>
  );
}

function Transcript({ state, update }) {
  return (
    <View style={styles.transcriptPage}>
      <Text style={styles.sectionEyebrow}>TRANSCRIPT</Text>
      <TextInput
        accessibilityLabel="Transcript"
        multiline
        onChangeText={(value) => update('setTranscriptText', value)}
        placeholderTextColor={colors.tertiary}
        style={styles.transcriptInput}
        textAlignVertical="top"
        value={state.transcriptText}
      />
      <View style={styles.rowActions}>
        <View style={styles.flex}><Button onPress={() => update('copyTranscript')}>Copy</Button></View>
        <Button destructive onPress={() => update('clearTranscript')} secondary>Clear</Button>
      </View>
    </View>
  );
}

function Ready({ openHistory, openSettings }) {
  return (
    <View style={styles.readyPage}>
      <View style={styles.iconTile}><Text style={styles.waveIcon}>≋</Text></View>
      <Text style={styles.readyTitle}>Ready</Text>
      <Text style={styles.mutedCenter}>Start from Control Center.</Text>
      <View style={styles.readyActions}>
        <Button onPress={openHistory} secondary>History</Button>
        <Button onPress={openSettings} secondary>Settings</Button>
      </View>
    </View>
  );
}

function ErrorScreen({ state, update, openSettings }) {
  let action;
  if (!state.hasAPIKey) action = <Button onPress={openSettings}>Add API key</Button>;
  else if (state.hasRecoverableRecording) action = (
    <View style={styles.fullWidthActions}>
      <Button onPress={() => update('retryAfterError')}>Retry</Button>
      <Button destructive onPress={() => update('discardRecoverableRecording')} secondary>Discard Audio</Button>
    </View>
  );
  else action = <Button onPress={() => update('dismissError')}>Dismiss</Button>;
  return (
    <View style={styles.centeredPage}>
      <Text style={styles.errorGlyph}>!</Text>
      <Text style={styles.errorMessage}>{state.errorText}</Text>
      {action}
    </View>
  );
}

function Settings({ close, state, update }) {
  const [apiKey, setAPIKey] = useState('');
  const [showLanguages, setShowLanguages] = useState(false);
  const saveKey = async () => {
    if (!apiKey.trim()) return;
    try {
      await update('saveAPIKey', apiKey);
      setAPIKey('');
    } catch (error) {
      Alert.alert("Couldn't update key", error.message);
    }
  };

  return (
    <SafeAreaView style={styles.sheet}>
      <Header onClose={close} title="Settings" />
      <ScrollView contentContainerStyle={styles.sheetContent}>
        <Text style={styles.groupTitle}>KEYBOARD</Text>
        <View style={styles.groupCard}>
          <Text style={styles.cardTitle}>Dictation Button Keyboard</Text>
          <Text style={styles.cardDetail}>Managed by iOS</Text>
          <Button onPress={() => update('openKeyboardSettings')} secondary small>Open Keyboard Settings</Button>
        </View>

        <Text style={styles.groupTitle}>SPEECH API KEY</Text>
        <View style={styles.groupCard}>
          <Text style={styles.cardTitle}>{state.hasAPIKey ? '✓ API key saved' : 'No API key saved'}</Text>
          <Text style={styles.cardDetail}>Use your own ElevenLabs key with speech-to-text access. Saved securely in this device's Keychain. Usage is charged to your ElevenLabs account.</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            onChangeText={setAPIKey}
            placeholder={state.hasAPIKey ? 'Paste a replacement key' : 'Paste your speech API key'}
            placeholderTextColor={colors.tertiary}
            secureTextEntry
            style={styles.field}
            value={apiKey}
          />
          <Button disabled={!apiKey.trim()} onPress={saveKey} small>Save Key</Button>
          {state.hasAPIKey ? <Button destructive onPress={() => update('deleteAPIKey')} secondary small>Remove Key</Button> : null}
        </View>

        <Text style={styles.groupTitle}>TRANSCRIPTION</Text>
        <View style={styles.groupCard}>
          <Pressable onPress={() => setShowLanguages(true)} style={styles.settingRow}>
            <Text style={styles.cardTitle}>Language</Text><Text style={styles.cardDetail}>{state.language.title} ›</Text>
          </Pressable>
          <View style={styles.settingRow}><Text style={styles.cardTitle}>Clean Speech</Text><Switch onValueChange={(value) => update('setCleanSpeech', value)} value={state.cleanSpeech} /></View>
          <View style={styles.settingRow}><Text style={styles.cardTitle}>Auto-copy transcript</Text><Switch onValueChange={(value) => update('setAutoCopy', value)} value={state.autoCopy} /></View>
        </View>

        <Text style={styles.groupTitle}>HISTORY RETENTION</Text>
        <View style={styles.groupCard}>
          {Object.entries(retentionLabels).map(([value, label]) => (
            <Pressable key={value} onPress={() => update('setHistoryRetention', value)} style={styles.settingRow}>
              <Text style={styles.cardTitle}>{label}</Text><Text style={styles.selection}>{state.historyRetention === value ? '✓' : ''}</Text>
            </Pressable>
          ))}
        </View>

        <Text style={styles.privacyText}>Audio is sent directly to ElevenLabs for transcription, including live drafts while recording. Transcripts and retained audio stay in local History. Sentry receives crash reports and operational diagnostics without audio, transcript text, or API keys. Dictation Button is independent of ElevenLabs.</Text>
        <Button onPress={() => Linking.openURL(privacyURL)} secondary small>Privacy policy</Button>
        <Button onPress={() => Linking.openURL(supportURL)} secondary small>Help and support</Button>
      </ScrollView>
      <Modal animationType="slide" visible={showLanguages}>
        <LanguagePicker close={() => setShowLanguages(false)} languages={state.languages} selected={state.language.rawValue} update={update} />
      </Modal>
    </SafeAreaView>
  );
}

function LanguagePicker({ close, languages, selected, update }) {
  const [query, setQuery] = useState('');
  const filtered = languages.filter((language) => language.title.toLowerCase().includes(query.trim().toLowerCase()));
  return (
    <SafeAreaView style={styles.sheet}>
      <Header onClose={close} title="Language" />
      <View style={styles.languageBody}>
        <TextInput onChangeText={setQuery} placeholder="Search languages" placeholderTextColor={colors.tertiary} style={styles.field} value={query} />
        <ScrollView>
          {filtered.map((language) => (
            <Pressable key={language.rawValue} onPress={async () => { await update('setLanguage', language.rawValue); close(); }} style={styles.languageRow}>
              <Text style={styles.cardTitle}>{language.title}</Text><Text style={styles.selection}>{selected === language.rawValue ? '✓' : ''}</Text>
            </Pressable>
          ))}
        </ScrollView>
      </View>
    </SafeAreaView>
  );
}

function History({ close, state, update }) {
  const [editing, setEditing] = useState(null);
  const [text, setText] = useState('');
  const beginEdit = (item) => { setEditing(item); setText(item.text); };
  const save = async () => { await update('updateHistoryItem', editing.id, text); setEditing(null); };
  return (
    <SafeAreaView style={styles.sheet}>
      <Header onClose={close} title="History" />
      {editing ? (
        <View style={styles.editorBody}>
          <TextInput multiline onChangeText={setText} placeholderTextColor={colors.tertiary} style={styles.transcriptInput} textAlignVertical="top" value={text} />
          <Button disabled={!text.trim()} onPress={save}>Save</Button>
          <Button onPress={() => setEditing(null)} secondary>Cancel</Button>
        </View>
      ) : state.history.length ? (
        <ScrollView contentContainerStyle={styles.historyList}>
          {state.history.map((item) => (
            <View key={item.id} style={styles.historyCard}>
              <Pressable onPress={() => beginEdit(item)}><Text numberOfLines={4} style={styles.historyText}>{item.text}</Text></Pressable>
              <Text style={styles.historyMeta}>{new Date(item.createdAt).toLocaleString()} · {formatDuration(item.duration)}</Text>
              {item.hasAudio ? (
                <Text style={styles.audioMeta}>{item.audioSignalLabel} · {item.microphoneModeLabel} · private on-device audio</Text>
              ) : null}
              <View style={styles.historyActions}>
                {item.hasAudio ? (
                  <Button onPress={() => update('toggleHistoryAudio', item.id)} secondary small>{item.audioPlaying ? 'Stop audio' : 'Play audio'}</Button>
                ) : null}
                {item.hasAudio ? (
                  <Button
                    onPress={async () => {
                      await update('reportHistoryAudioIssue', item.id);
                      Alert.alert('Reported', 'The private audio stayed on this iPhone. Only coarse signal and microphone-mode diagnostics were sent.');
                    }}
                    secondary
                    small
                  >Report garbled</Button>
                ) : null}
                <Button onPress={() => update('copyHistoryItem', item.id)} secondary small>Copy</Button>
                <Button onPress={async () => { await update('useHistoryItem', item.id); close(); }} secondary small>Use</Button>
                <Button destructive onPress={() => update('deleteHistoryItem', item.id)} secondary small>Delete</Button>
              </View>
            </View>
          ))}
          <Text style={styles.audioPrivacy}>Original audio is retained privately with History while space allows, up to 250 MB. Deleting a transcript deletes its retained audio.</Text>
          <Button destructive onPress={() => update('clearHistory')} secondary>Clear All</Button>
        </ScrollView>
      ) : (
        <View style={styles.centeredPage}><Text style={styles.largeTitle}>No Transcripts Yet</Text><Text style={styles.bodyCenter}>Finished dictations are saved here, on this device only.</Text></View>
      )}
    </SafeAreaView>
  );
}

export default function App() {
  // Native capture can already be starting when React mounts after a Control
  // Center launch. Do not paint the onboarding defaults while the exact native
  // snapshot is still crossing the bridge; that produced a one-frame "Add the
  // keyboard" flash before the real recording screen appeared.
  const [state, setState] = useState(null);
  const [showSettings, setShowSettings] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const mounted = useRef(true);
  const isDarkMode = useColorScheme() === 'dark';

  const update = useCallback(async (method, ...args) => {
    if (!nativeApp?.[method]) throw new Error(`Native method ${method} is unavailable in this binary.`);
    const next = await nativeApp[method](...args);
    if (next && mounted.current) setState(next);
    return next;
  }, []);

  useEffect(() => {
    mounted.current = true;
    if (!nativeApp) {
      setState({ ...emptyState, phase: 'failed', errorText: 'Install the Expo-enabled Dictation Button binary.' });
      return () => { mounted.current = false; };
    }
    const emitter = new NativeEventEmitter(nativeApp);
    const subscription = emitter.addListener('ElevenLabsStateChanged', setState);
    update('getState').catch(() => {
      if (mounted.current) {
        setState({ ...emptyState, phase: 'failed', errorText: 'Dictation Button could not load its native state.' });
      }
    });
    return () => { mounted.current = false; subscription.remove(); };
  }, [update]);

  if (!state || !state.launchStateReady) {
    // Match the native launch color and keep the surface intentionally neutral
    // until the foreground scene crosses the native lifecycle boundary. The
    // current Control Center toggle is headless and never opens this scene.
    return (
      <SafeAreaView style={styles.screen}>
        <StatusBar style={isDarkMode ? 'light' : 'dark'} />
      </SafeAreaView>
    );
  }

  const sessionVisible = state.isPreparingKeyboardSession || state.phase === 'recording' || state.phase === 'paused' || (state.isKeyboardDictation && state.phase === 'transcribing');
  const isSessionScreen = sessionVisible || state.phase === 'transcribing';

  let content;
  if (sessionVisible) content = <Session state={state} />;
  else if (state.phase === 'failed') content = <ErrorScreen openSettings={() => setShowSettings(true)} state={state} update={update} />;
  else if (!state.hasAPIKey || !state.completedOnboarding) content = <Onboarding openSettings={() => setShowSettings(true)} state={state} update={update} />;
  else if (state.phase === 'transcribing') content = <Session state={state} />;
  else if (state.transcriptText) content = <Transcript state={state} update={update} />;
  else content = <Ready openHistory={() => setShowHistory(true)} openSettings={() => setShowSettings(true)} />;

  return (
    <SafeAreaView style={[styles.screen, isSessionScreen && styles.sessionScreen, state.phase === 'paused' && styles.sessionScreenPaused]}>
      <StatusBar style={isSessionScreen && state.phase !== 'paused' ? 'light' : (isDarkMode ? 'light' : 'dark')} />
      {!isSessionScreen ? <View style={styles.wordmark}><Text style={styles.wordmarkText}>Dictation Button</Text></View> : null}
      {content}
      {state.recordingNotice ? <View style={styles.notice}><Text style={styles.noticeText}>{state.recordingNotice}</Text></View> : null}
      <Modal animationType="slide" visible={showSettings}><Settings close={() => setShowSettings(false)} state={state} update={update} /></Modal>
      <Modal animationType="slide" visible={showHistory}><History close={() => setShowHistory(false)} state={state} update={update} /></Modal>
    </SafeAreaView>
  );
}

const adaptiveColor = (light, dark) => DynamicColorIOS({ light, dark });
const colors = {
  background: adaptiveColor('#fdfcfc', '#000000'),
  surface: adaptiveColor('#ffffff', '#151412'),
  raised: adaptiveColor('#f4f2f0', '#24211f'),
  ink: adaptiveColor('#000000', '#ffffff'),
  onInk: adaptiveColor('#ffffff', '#000000'),
  muted: adaptiveColor('#777169', '#aaa49d'),
  tertiary: adaptiveColor('#97918a', '#8f8982'),
  danger: adaptiveColor('#d70015', '#ff453a'),
  ice: adaptiveColor('#4aaaff', '#64d2ff'),
  border: adaptiveColor('#dedbd8', '#3a3734'),
  borderSoft: adaptiveColor('#e1dfdc', '#302e2b'),
  divider: adaptiveColor('#eeecea', '#2d2a28'),
  pausedBackground: adaptiveColor('#ddf2ff', '#071a2b'),
  pausedInk: adaptiveColor('#0066cc', '#64b5ff'),
  pausedInkMuted: adaptiveColor('rgba(0,102,204,0.44)', 'rgba(100,181,255,0.52)'),
  pausedTrack: adaptiveColor('rgba(0,102,204,0.22)', 'rgba(100,181,255,0.25)'),
  pausedBar: adaptiveColor('rgba(0,102,204,0.36)', 'rgba(100,181,255,0.40)'),
};
const styles = StyleSheet.create({
  screen: { backgroundColor: colors.background, flex: 1 },
  sessionScreen: { backgroundColor: '#000000' },
  sessionScreenPaused: { backgroundColor: colors.pausedBackground },
  wordmark: { alignItems: 'center', flexDirection: 'row', gap: 8, justifyContent: 'center', paddingTop: 14 },
  wordmarkText: { color: colors.ink, fontSize: 17, fontWeight: '700' },
  centeredPage: { alignItems: 'center', flex: 1, gap: 20, justifyContent: 'center', padding: 28 },
  step: { backgroundColor: colors.raised, borderRadius: 18, color: colors.muted, fontSize: 12, fontWeight: '700', letterSpacing: 1.3, overflow: 'hidden', paddingHorizontal: 14, paddingVertical: 9 },
  iconTile: { alignItems: 'center', backgroundColor: colors.surface, borderColor: colors.border, borderRadius: 25, borderWidth: 1, height: 112, justifyContent: 'center', width: 112 },
  waveIcon: { color: colors.ink, fontSize: 54, fontWeight: '300', transform: [{ rotate: '90deg' }] },
  sendCircle: { alignItems: 'center', backgroundColor: colors.ink, borderRadius: 54, height: 108, justifyContent: 'center', width: 108 },
  sendGlyph: { color: colors.onInk, fontSize: 40, transform: [{ rotate: '-45deg' }] },
  largeTitle: { color: colors.ink, fontSize: 37, fontWeight: '300', letterSpacing: -1, textAlign: 'center' },
  bodyCenter: { color: colors.muted, fontSize: 16, lineHeight: 23, textAlign: 'center' },
  mutedCenter: { color: colors.muted, fontSize: 15, lineHeight: 21, textAlign: 'center' },
  captionCenter: { color: colors.tertiary, fontSize: 12, lineHeight: 17, textAlign: 'center' },
  tipCard: { backgroundColor: colors.surface, borderColor: colors.borderSoft, borderRadius: 20, borderWidth: 1, gap: 8, padding: 18, width: '100%' },
  tipText: { color: colors.muted, fontSize: 14, lineHeight: 20, textAlign: 'center' },
  checkLine: { color: colors.ink, fontSize: 14, lineHeight: 21 },
  fullWidthActions: { gap: 10, width: '100%' },
  button: { alignItems: 'center', backgroundColor: colors.ink, borderColor: colors.ink, borderRadius: 14, borderWidth: 1.5, justifyContent: 'center', minHeight: 50, paddingHorizontal: 18 },
  buttonLabel: { color: colors.onInk, fontSize: 16, fontWeight: '700' },
  buttonSecondary: { backgroundColor: 'transparent' },
  buttonSecondaryLabel: { color: colors.ink },
  buttonDestructive: { borderColor: colors.danger },
  buttonDestructiveLabel: { color: colors.danger },
  buttonSmall: { minHeight: 40, paddingHorizontal: 13 },
  disabled: { opacity: 0.4 },
  pressed: { opacity: 0.68 },
  sessionPage: { backgroundColor: '#000000', flex: 1, paddingBottom: 12, paddingHorizontal: 30, paddingTop: 24 },
  sessionPagePaused: { backgroundColor: colors.pausedBackground },
  sessionStatus: { alignItems: 'center', alignSelf: 'center', flexDirection: 'row', gap: 8, minHeight: 24 },
  sessionStatusText: { color: '#ffffff', fontSize: 15, fontWeight: '600' },
  sessionDuration: { color: '#ffffff', fontSize: 15, fontVariant: ['tabular-nums'], fontWeight: '500' },
  statusSeparator: { color: 'rgba(255,255,255,0.44)', fontSize: 15 },
  statusSeparatorPaused: { color: colors.pausedInkMuted },
  pausedInk: { color: colors.pausedInk },
  sessionCenter: { alignItems: 'center', flex: 1, gap: 22, justifyContent: 'center' },
  processingTitle: { color: '#ffffff', fontSize: 20, fontWeight: '500', textAlign: 'center' },
  waveform: { alignItems: 'center', flexDirection: 'row', gap: 4, height: 180, justifyContent: 'center', width: '100%' },
  processingSpinner: { height: 92 },
  waveColumn: { alignItems: 'center', justifyContent: 'flex-start' },
  waveBar: { backgroundColor: '#ffffff', borderRadius: 4, maxHeight: 170, width: 5 },
  waveBarFrozen: { backgroundColor: colors.pausedBar, maxHeight: 132 },
  wavePeakCap: { backgroundColor: colors.pausedInk, borderRadius: 2, height: 3, position: 'absolute', top: 0, width: 6 },
  swipeCue: { alignItems: 'center', alignSelf: 'stretch', gap: 12, paddingBottom: 2 },
  swipeCueTitle: { color: '#ffffff', fontSize: 17, fontWeight: '600' },
  swipeTrack: { backgroundColor: 'rgba(255,255,255,0.22)', borderRadius: 3, height: 5, overflow: 'hidden', width: 134 },
  swipeTrackPaused: { backgroundColor: colors.pausedTrack },
  swipeThumb: { backgroundColor: '#ffffff', borderRadius: 3, height: 5, width: 52 },
  swipeThumbPaused: { backgroundColor: colors.pausedInk },
  transcriptPage: { flex: 1, gap: 14, padding: 22 },
  sectionEyebrow: { color: colors.muted, fontSize: 12, fontWeight: '800', letterSpacing: 1.2 },
  transcriptInput: { backgroundColor: colors.surface, borderColor: colors.border, borderRadius: 22, borderWidth: 1, color: colors.ink, flex: 1, fontSize: 17, lineHeight: 24, minHeight: 190, padding: 16 },
  rowActions: { flexDirection: 'row', gap: 12 },
  flex: { flex: 1 },
  readyPage: { alignItems: 'center', flex: 1, gap: 18, justifyContent: 'center', padding: 28 },
  readyTitle: { color: colors.ink, fontSize: 42, fontWeight: '300', letterSpacing: -1 },
  readyActions: { bottom: 28, flexDirection: 'row', gap: 12, position: 'absolute' },
  errorGlyph: { color: colors.danger, fontSize: 58, fontWeight: '300' },
  errorMessage: { color: colors.ink, fontSize: 17, lineHeight: 24, textAlign: 'center' },
  notice: { alignSelf: 'center', backgroundColor: colors.ink, borderRadius: 12, bottom: 18, maxWidth: '88%', paddingHorizontal: 16, paddingVertical: 11, position: 'absolute' },
  noticeText: { color: colors.onInk, fontSize: 13, textAlign: 'center' },
  sheet: { backgroundColor: colors.background, flex: 1 },
  sheetHeader: { alignItems: 'center', borderBottomColor: colors.borderSoft, borderBottomWidth: 1, flexDirection: 'row', justifyContent: 'space-between', paddingHorizontal: 20, paddingVertical: 14 },
  sheetTitle: { color: colors.ink, fontSize: 22, fontWeight: '750' },
  closeButton: { padding: 8 },
  closeButtonLabel: { color: colors.ink, fontSize: 16, fontWeight: '700' },
  sheetContent: { gap: 9, padding: 20, paddingBottom: 44 },
  groupTitle: { color: colors.muted, fontSize: 12, fontWeight: '800', letterSpacing: 0.8, marginTop: 13 },
  groupCard: { backgroundColor: colors.surface, borderColor: colors.borderSoft, borderRadius: 18, borderWidth: 1, gap: 11, padding: 16 },
  cardTitle: { color: colors.ink, fontSize: 16, fontWeight: '650' },
  cardDetail: { color: colors.muted, fontSize: 14, lineHeight: 19 },
  field: { backgroundColor: colors.raised, borderColor: colors.border, borderRadius: 12, borderWidth: 1, color: colors.ink, fontSize: 16, minHeight: 48, paddingHorizontal: 13 },
  settingRow: { alignItems: 'center', borderBottomColor: colors.divider, borderBottomWidth: 1, flexDirection: 'row', justifyContent: 'space-between', minHeight: 44 },
  selection: { color: colors.ink, fontSize: 18, fontWeight: '800' },
  privacyText: { color: colors.muted, fontSize: 13, lineHeight: 19, marginTop: 14, textAlign: 'center' },
  languageBody: { flex: 1, gap: 12, padding: 20 },
  languageRow: { alignItems: 'center', borderBottomColor: colors.divider, borderBottomWidth: 1, flexDirection: 'row', justifyContent: 'space-between', minHeight: 50 },
  historyList: { gap: 13, padding: 20, paddingBottom: 42 },
  historyCard: { backgroundColor: colors.surface, borderColor: colors.borderSoft, borderRadius: 18, borderWidth: 1, gap: 9, padding: 16 },
  historyText: { color: colors.ink, fontSize: 16, lineHeight: 22 },
  historyMeta: { color: colors.muted, fontSize: 12 },
  audioMeta: { color: colors.pausedInk, fontSize: 12, lineHeight: 17 },
  audioPrivacy: { color: colors.muted, fontSize: 12, lineHeight: 18, textAlign: 'center' },
  historyActions: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  editorBody: { flex: 1, gap: 12, padding: 20 },
});
