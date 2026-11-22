// This device's notification state and the steps to change it.
import { getPushKey, pushSubscribe, pushUnsubscribe, pushTest } from './api.js';

export function pushSupport() {
  if (!window.isSecureContext) return 'insecure';
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
    // iPhone Safari only offers push to apps added to the home screen.
    const ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
    const standalone = window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone;
    return ios && !standalone ? 'ios-install' : 'unsupported';
  }
  return 'ok';
}

async function registration() {
  return (await navigator.serviceWorker.getRegistration()) ?? navigator.serviceWorker.register('/sw.js');
}

export async function currentSubscription() {
  const reg = await registration();
  return reg.pushManager.getSubscription();
}

function keyBytes(b64) {
  const s = b64.replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(s + '='.repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

// Must run from a tap: browsers only ask for permission then.
export async function turnOn() {
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    throw new Error(permission === 'denied'
      ? 'Notifications are blocked for Clankstation. Allow them in this device\'s settings, then try again.'
      : 'Notifications weren\'t allowed.');
  }
  const reg = await registration();
  await navigator.serviceWorker.ready;
  const { key } = await getPushKey();
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
  }
  await pushSubscribe(sub.toJSON());
  return sub;
}

export async function turnOff() {
  const sub = await currentSubscription();
  if (!sub) return;
  await pushUnsubscribe(sub.endpoint).catch(() => {});
  await sub.unsubscribe();
}

export async function sendTest() {
  const sub = await currentSubscription();
  if (!sub) throw new Error('Turn notifications on first.');
  await pushTest(sub.endpoint);
}
