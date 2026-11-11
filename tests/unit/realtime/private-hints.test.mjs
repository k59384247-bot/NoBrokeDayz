import assert from "node:assert/strict";
import test from "node:test";
import { createPrivateRealtimeManager } from "../../../lib/realtime/private-hints.mjs";

function fakeSupabase() {
  const channels = [];
  let authChange;
  const supabase = {
    channel(topic, options) {
      const channel = {
        topic,
        options,
        handlers: new Map(),
        on(_type, filter, callback) {
          this.handlers.set(filter.event, callback);
          return this;
        },
        subscribe(callback) {
          this.status = callback;
          queueMicrotask(() => callback("SUBSCRIBED"));
          return this;
        },
        emit(event, payload = { kind: "invalidate" }, envelope = true) {
          this.handlers.get(event)?.(envelope ? { payload } : payload);
        },
      };
      channels.push(channel);
      return channel;
    },
    async removeChannel(channel) {
      channel.removed = true;
      return "ok";
    },
    realtime: {
      async setAuth(token) {
        supabase.token = token;
      },
    },
    auth: {
      onAuthStateChange(callback) {
        authChange = callback;
        return { data: { subscription: { unsubscribe() {} } } };
      },
    },
  };
  return {
    supabase,
    channels,
    signedOut() {
      authChange?.("SIGNED_OUT", null);
    },
  };
}

const message = (sequence) => ({
  sequence,
  message_id: `message-${sequence}`,
});

test("thread replay paginates exact decimal sequences and absorbs a subscribe race", async () => {
  const fake = fakeSupabase();
  const manager = createPrivateRealtimeManager(fake.supabase);
  const snapshots = [];
  let pageCalls = 0;
  let handle;
  handle = await manager.subscribeApplicationThread({
    topic: "nbd:thread:app:actor:user:g:3",
    accessToken: "auth-token",
    afterSequence: "9007199254740992",
    loadPage: async (after) => {
      pageCalls += 1;
      if (pageCalls === 1) {
        fake.channels[0].emit("thread.changed");
        return {
          thread: {
            last_sequence: "9007199254740994",
            read_cursor: "0",
            messages: [message("9007199254740993")],
          },
          next_after_sequence: "9007199254740993",
        };
      }
      if (after === "9007199254740993")
        return {
          thread: {
            last_sequence: "9007199254740994",
            read_cursor: "0",
            messages: [message("9007199254740994")],
          },
          next_after_sequence: null,
        };
      return {
        thread: {
          last_sequence: "9007199254740994",
          read_cursor: "0",
          messages: [],
        },
        next_after_sequence: null,
      };
    },
    onSnapshot: (snapshot) => snapshots.push(snapshot),
  });
  await handle.ready;

  assert.equal(fake.channels[0].options.config.private, true);
  assert.deepEqual(
    handle.messages.map((row) => row.sequence),
    ["9007199254740993", "9007199254740994"],
  );
  assert.equal(handle.cursor, "9007199254740994");
  assert.ok(pageCalls >= 2);
  assert.ok(snapshots.length >= 2);
  const beforeReconnect = pageCalls;
  fake.channels[0].status("SUBSCRIBED");
  while (pageCalls === beforeReconnect)
    await new Promise((resolve) => setImmediate(resolve));
  assert.equal(handle.messages.length, 2);
  await handle.dispose();
  await manager.dispose();
});

test("thread changes and logout remove their private channels", async () => {
  const fake = fakeSupabase();
  const manager = createPrivateRealtimeManager(fake.supabase);
  const loadPage = async () => ({
    thread: { last_sequence: "0", read_cursor: "0" },
    messages: [],
    next_after_sequence: null,
  });
  const first = await manager.subscribeApplicationThread({
    topic: "nbd:thread:first:actor:user:g:1",
    accessToken: "auth-token",
    loadPage,
    onSnapshot() {},
  });
  await first.ready;
  const second = await manager.subscribeApplicationThread({
    topic: "nbd:thread:second:actor:user:g:1",
    accessToken: "auth-token",
    loadPage,
    onSnapshot() {},
  });
  await second.ready;
  assert.equal(first.closed, true);
  assert.equal(fake.channels[0].removed, true);
  fake.signedOut();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(second.closed, true);
  assert.equal(fake.channels[1].removed, true);
  await manager.dispose();
});

test("broadcast handler accepts the Supabase client payload shape", async () => {
  const fake = fakeSupabase();
  const manager = createPrivateRealtimeManager(fake.supabase);
  const hints = [];
  const subscription = await manager.subscribeInvalidation({
    key: "notifications",
    topic: "nbd:notifications:actor:user:g:2",
    event: "notifications.changed",
    accessToken: "auth-token",
    onInvalidate: (hint) => hints.push(hint),
  });
  await subscription.ready;
  fake.channels[0].emit(
    "notifications.changed",
    { id: "realtime-message-id", kind: "invalidate" },
    false,
  );
  assert.deepEqual(hints, [
    { event: "notifications.changed", payload: { kind: "invalidate" } },
  ]);
  await manager.dispose();
});
