import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const ids = {
  pt: "00000000-0000-4000-8000-000000000001",
  other: "00000000-0000-4000-8000-000000000002",
  member: "00000000-0000-4000-8000-000000000003",
  stranger: "00000000-0000-4000-8000-000000000004",
};
test("migration and PT/customer isolation on an isolated PostgreSQL instance", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(
      await readFile(new URL("./baseline.sql", import.meta.url), "utf8"),
    );
    await db.exec(
      await readFile(
        new URL(
          "../supabase/migrations/20260916035940_connect_shared_database.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    for (const id of Object.values(ids))
      await db.query("insert into auth.users(id) values($1)", [id]);
    async function as(who) {
      await db.exec("reset role");
      await db.query("select set_config('request.jwt.claim.sub',$1,false)", [
        ids[who] || "",
      ]);
      await db.exec("set role authenticated");
    }
    for (const [who, id] of Object.entries(ids)) {
      await as(who);
      await db.query(
        "insert into public.profiles(id,role,full_name) values($1,$2,$3)",
        [id, ["pt", "other"].includes(who) ? "pt" : "member", who],
      );
    }
    await as("pt");
    const client = (
      await db.query(
        "insert into public.clients(pt_id,full_name) values($1,'Test client') returning *",
        [ids.pt],
      )
    ).rows[0];
    await t.test("other trainer cannot read or edit client", async () => {
      await as("other");
      assert.equal(
        (await db.query("select * from public.clients")).rows.length,
        0,
      );
      assert.equal(
        (
          await db.query(
            "update public.clients set full_name='hacked' where id=$1 returning id",
            [client.id],
          )
        ).rows.length,
        0,
      );
      await assert.rejects(
        db.query(
          "insert into public.sessions(pt_id,client_id,starts_at) values($1,$2,now())",
          [ids.other, client.id],
        ),
        /row-level security/,
      );
    });
    await t.test(
      "customer cannot impersonate a trainer or reassign a client",
      async () => {
        await as("member");
        await assert.rejects(
          db.query("update public.profiles set role='pt' where id=$1", [
            ids.member,
          ]),
          /permission denied/,
        );
        await assert.rejects(
          db.query(
            "insert into public.clients(pt_id,full_name) values($1,'fake')",
            [ids.member],
          ),
          /row-level security/,
        );
      },
    );
    await t.test("invitation links once and cannot be reused", async () => {
      await as("member");
      assert.equal(
        (
          await db.query("select public.accept_invitation($1) as id", [
            client.invite_token,
          ])
        ).rows[0].id,
        client.id,
      );
      assert.equal(
        (await db.query("select * from public.clients")).rows.length,
        1,
      );
      await assert.rejects(
        db.query("select public.accept_invitation($1)", [client.invite_token]),
        /Invalid or already used/,
      );
      await as("stranger");
      await assert.rejects(
        db.query("select public.accept_invitation($1)", [client.invite_token]),
        /Invalid or already used/,
      );
      assert.equal(
        (await db.query("select * from public.clients")).rows.length,
        0,
      );
    });
    let session, payment, message, availability, task;
    await t.test(
      "trainer creates session, package, task and message",
      async () => {
        await as("pt");
        session = (
          await db.query(
            "insert into public.sessions(client_id,pt_id,starts_at,ends_at) values($1,$2,'2026-09-01 10:00Z','2026-09-01 11:00Z') returning id",
            [client.id, ids.pt],
          )
        ).rows[0].id;
        await db.query(
          "insert into public.packages(client_id,price,total_sessions,start_date,expiry_date) values($1,7500,12,'2026-09-01','2026-09-30')",
          [client.id],
        );
        task = (
          await db.query(
            "insert into public.tasks(client_id,pt_id,title) values($1,$2,'Tartıl') returning id",
            [client.id, ids.pt],
          )
        ).rows[0].id;
        message = (
          await db.query(
            "insert into public.messages(client_id,sender_id,body) values($1,$2,'Su iç') returning id",
            [client.id, ids.pt],
          )
        ).rows[0].id;
      },
    );
    await t.test(
      "customer reads trainer records but cannot change session result",
      async () => {
        await as("member");
        assert.equal(
          (await db.query("select * from public.sessions")).rows.length,
          1,
        );
        assert.equal(
          (await db.query("select * from public.packages")).rows.length,
          1,
        );
        assert.equal(
          (
            await db.query(
              "update public.sessions set status='completed' where id=$1 returning id",
              [session],
            )
          ).rows.length,
          0,
        );
      },
    );
    await t.test(
      "customer may submit payment but cannot approve it",
      async () => {
        await as("member");
        payment = (
          await db.query(
            "insert into public.payments(client_id,amount,status) values($1,7500,'pending') returning id",
            [client.id],
          )
        ).rows[0].id;
        assert.equal(
          (
            await db.query(
              "update public.payments set status='approved' where id=$1 returning id",
              [payment],
            )
          ).rows.length,
          0,
        );
        await assert.rejects(
          db.query(
            "insert into public.payments(client_id,amount,status) values($1,7500,'approved')",
            [client.id],
          ),
          /row-level security/,
        );
        await as("pt");
        assert.equal(
          (
            await db.query(
              "update public.payments set status='approved' where id=$1 returning status",
              [payment],
            )
          ).rows[0].status,
          "approved",
        );
      },
    );
    await t.test(
      "message sender cannot be forged and customer can mark messages read",
      async () => {
        await as("member");
        await assert.rejects(
          db.query(
            "insert into public.messages(client_id,sender_id,body) values($1,$2,'fake')",
            [client.id, ids.pt],
          ),
          /row-level security/,
        );
        await db.query("update public.messages set read_at=now() where id=$1", [
          message,
        ]);
        await db.query(
          "insert into public.messages(client_id,sender_id,body) values($1,$2,'10 dk gecikeceğim')",
          [client.id, ids.member],
        );
        await as("pt");
        assert.ok(
          (
            await db.query("select read_at from public.messages where id=$1", [
              message,
            ])
          ).rows[0].read_at,
        );
      },
    );
    await t.test(
      "customer can return task result but cannot rewrite ownership or title",
      async () => {
        await as("member");
        await db.query(
          "update public.tasks set status='done',result='89 kg' where id=$1",
          [task],
        );
        await assert.rejects(
          db.query("update public.tasks set title='fake' where id=$1", [task]),
          /permission denied/,
        );
      },
    );
    await t.test(
      "customer absence is visible to trainer and deletable only by customer",
      async () => {
        await as("member");
        availability = (
          await db.query(
            "insert into public.availability(client_id,starts_at,ends_at,kind,note) values($1,'2026-09-01 10:00Z','2026-09-01 11:00Z','unavailable','İzinliyim') returning id",
            [client.id],
          )
        ).rows[0].id;
        await as("pt");
        assert.equal(
          (
            await db.query("select note from public.availability where id=$1", [
              availability,
            ])
          ).rows[0].note,
          "İzinliyim",
        );
        assert.equal(
          (
            await db.query(
              "delete from public.availability where id=$1 returning id",
              [availability],
            )
          ).rows.length,
          0,
        );
        await as("member");
        assert.equal(
          (
            await db.query(
              "delete from public.availability where id=$1 returning id",
              [availability],
            )
          ).rows.length,
          1,
        );
      },
    );
    await t.test("unrelated account cannot see any client data", async () => {
      await as("stranger");
      for (const table of [
        "clients",
        "packages",
        "sessions",
        "payments",
        "tasks",
        "messages",
      ])
        assert.equal(
          (await db.query(`select * from public.${table}`)).rows.length,
          0,
          table,
        );
    });
    await t.test(
      "anonymous account cannot read client tables or consume invitation",
      async () => {
        await db.exec("reset role; set role anon");
        await assert.rejects(
          db.query("select * from public.clients"),
          /permission denied/,
        );
        await assert.rejects(
          db.query("select public.accept_invitation($1)", [
            client.invite_token,
          ]),
          /permission denied/,
        );
      },
    );
  } finally {
    await db.close();
  }
});
