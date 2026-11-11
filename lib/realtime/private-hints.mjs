const DECIMAL_SEQUENCE = /^(?:0|[1-9][0-9]*)$/;
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;
const MAX_REPLAY_PAGES = 100;

function sequence(value) {
  if (
    typeof value !== "string" ||
    !DECIMAL_SEQUENCE.test(value) ||
    BigInt(value) > MAX_SEQUENCE
  )
    throw new Error("invalid_realtime_sequence");
  return value;
}

function invalidationPayload(message) {
  const payload = message?.payload ?? message ?? null;
  return payload && typeof payload === "object" && payload.kind === "invalidate"
    ? { kind: "invalidate" }
    : null;
}

export async function fetchRealtimeTopic({
  supabaseUrl,
  anonKey,
  accessToken,
  scope,
  resourceId,
  fetchImpl = fetch,
}) {
  const response = await fetchImpl(
    `${new URL(supabaseUrl).origin}/functions/v1/realtime-topic`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        scope,
        ...(resourceId ? { resource_id: resourceId } : {}),
      }),
    },
  );
  const result = await response.json().catch(() => null);
  if (!response.ok || result?.data?.private !== true)
    throw new Error(result?.error?.code ?? "realtime_topic_unavailable");
  return result.data;
}

export function createPrivateRealtimeManager(supabase) {
  if (!supabase?.channel || !supabase?.removeChannel || !supabase?.realtime)
    throw new Error("a Supabase client with Realtime is required");

  const active = new Set();
  let disposed = false;

  async function removeActive(expected) {
    if (!expected) return;
    active.delete(expected);
    expected.closed = true;
    expected.rejectReady?.(new Error("realtime_subscription_closed"));
    await supabase.removeChannel(expected.channel);
  }

  async function start({
    key,
    topic,
    events,
    accessToken,
    onHint,
    onError,
    onSubscribed,
  }) {
    if (disposed) throw new Error("realtime_manager_disposed");
    if (
      typeof topic !== "string" ||
      !topic.startsWith("nbd:") ||
      !Array.isArray(events) ||
      events.length < 1 ||
      events.some((event) => typeof event !== "string") ||
      typeof accessToken !== "string" ||
      typeof onHint !== "function"
    )
      throw new Error("invalid_realtime_subscription");

    const previous = [...active].find((entry) => entry.key === key);
    if (previous) await removeActive(previous);
    await supabase.realtime.setAuth(accessToken);
    const channel = supabase.channel(topic, { config: { private: true } });
    let resolveReady;
    let rejectReady;
    const ready = new Promise((resolve, reject) => {
      resolveReady = resolve;
      rejectReady = reject;
    });
    ready.catch(() => {});
    const state = { channel, key, closed: false, rejectReady };
    active.add(state);

    for (const event of events) {
      channel.on("broadcast", { event }, (message) => {
        if (state.closed) return;
        try {
          onHint({ event, payload: invalidationPayload(message) });
        } catch (error) {
          onError?.(error);
        }
      });
    }
    channel.subscribe((status, error) => {
      if (state.closed) return;
      if (status === "SUBSCRIBED") {
        resolveReady();
        onSubscribed?.();
      } else if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)) {
        const label = ["thread", "notifications", "case"].includes(key)
          ? key
          : "channel";
        const connectionState =
          supabase.realtime.connectionState?.() ?? "unknown";
        const failure =
          error ??
          new Error(
            `realtime_${status.toLowerCase()}_${label}_${connectionState}`,
          );
        rejectReady(failure);
        onError?.(failure);
      }
    });

    return {
      ready,
      dispose: () => removeActive(state),
      get closed() {
        return state.closed;
      },
    };
  }

  async function subscribeInvalidation({
    key,
    topic,
    event,
    accessToken,
    onInvalidate,
    onError,
  }) {
    if (typeof onInvalidate !== "function")
      throw new Error("an invalidation callback is required");
    return start({
      key: key ?? topic,
      topic,
      events: [event],
      accessToken,
      onHint: onInvalidate,
      onError,
    });
  }

  async function subscribeApplicationThread({
    topic,
    accessToken,
    afterSequence = "0",
    loadPage,
    onSnapshot,
    onHint,
    onError,
  }) {
    let cursor = sequence(afterSequence);
    if (typeof loadPage !== "function" || typeof onSnapshot !== "function")
      throw new Error("thread replay dependencies are required");

    const bySequence = new Map();
    let snapshot = null;
    let dirty = false;
    let running = false;
    let subscribed = false;
    let retryCurrentReplay = false;
    let initialSubscription = true;
    let resolveInitialReplay;
    const initialReplay = new Promise((resolve) => {
      resolveInitialReplay = resolve;
    });

    async function replay() {
      dirty = true;
      if (running || !subscribed) return;
      running = true;
      try {
        while (dirty) {
          dirty = false;
          let pages = 0;
          let next = cursor;
          let hasMore = true;
          while (hasMore) {
            if (++pages > MAX_REPLAY_PAGES)
              throw new Error("realtime_replay_page_limit");
            const page = await loadPage(next);
            if (
              !page ||
              !page.thread ||
              !Array.isArray(page.thread.messages) ||
              (typeof page.next_after_sequence !== "string" &&
                page.next_after_sequence !== null)
            )
              throw new Error("invalid_realtime_replay_page");
            snapshot = page.thread;
            for (const message of page.thread.messages) {
              const messageSequence = sequence(message.sequence);
              const existing = bySequence.get(messageSequence);
              if (existing && existing.message_id !== message.message_id)
                throw new Error("realtime_sequence_conflict");
              bySequence.set(messageSequence, message);
            }
            const ordered = [...bySequence.values()].sort((left, right) =>
              BigInt(left.sequence) < BigInt(right.sequence)
                ? -1
                : BigInt(left.sequence) > BigInt(right.sequence)
                  ? 1
                  : 0,
            );
            const newest = ordered.at(-1)?.sequence;
            const proposedCursor =
              page.next_after_sequence ??
              (newest && BigInt(newest) > BigInt(cursor) ? newest : cursor);
            await onSnapshot({
              thread: snapshot,
              messages: ordered,
              lastSavedSequence: proposedCursor,
            });

            if (page.next_after_sequence === null) {
              hasMore = false;
              cursor = proposedCursor;
            } else {
              const boundary = sequence(page.next_after_sequence);
              if (BigInt(boundary) <= BigInt(next))
                throw new Error("realtime_replay_did_not_advance");
              next = boundary;
              cursor = boundary;
            }
          }
          if (retryCurrentReplay) {
            retryCurrentReplay = false;
            dirty = true;
          }
        }
      } catch (error) {
        onError?.(error);
      } finally {
        running = false;
        if (dirty && subscribed) void replay();
      }
    }

    const subscription = await start({
      key: "thread",
      topic,
      events: ["thread.changed", "thread.read_changed"],
      accessToken,
      onHint: (hint) => {
        onHint?.(hint);
        if (running) retryCurrentReplay = true;
        void replay();
      },
      onError,
      onSubscribed: () => {
        subscribed = true;
        if (initialSubscription) {
          initialSubscription = false;
          void replay().then(resolveInitialReplay);
        } else {
          void replay();
        }
      },
    });
    const startReady = subscription.ready.then(() => initialReplay);
    startReady.catch(onError ?? (() => {}));

    return {
      ready: startReady,
      dispose: subscription.dispose,
      get closed() {
        return subscription.closed;
      },
      get cursor() {
        return cursor;
      },
      get messages() {
        return [...bySequence.values()].sort((left, right) =>
          BigInt(left.sequence) < BigInt(right.sequence)
            ? -1
            : BigInt(left.sequence) > BigInt(right.sequence)
              ? 1
              : 0,
        );
      },
    };
  }

  const authListener = supabase.auth?.onAuthStateChange?.((event, session) => {
    if (event === "SIGNED_OUT") {
      for (const subscription of active) void removeActive(subscription);
    } else if (event === "TOKEN_REFRESHED" && session?.access_token) {
      void supabase.realtime.setAuth(session.access_token);
    }
  });

  return {
    subscribeInvalidation,
    subscribeApplicationThread,
    async clear(key) {
      const subscriptions = [...active].filter(
        (subscription) => key === undefined || subscription.key === key,
      );
      await Promise.all(subscriptions.map(removeActive));
    },
    async dispose() {
      disposed = true;
      authListener?.data?.subscription?.unsubscribe();
      await Promise.all([...active].map(removeActive));
    },
  };
}
