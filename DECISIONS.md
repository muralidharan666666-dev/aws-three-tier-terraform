# Decision log and debugging notes

These are the working notes I kept while rebuilding my three-tier AWS setup with Terraform. Written as I went along, so this is the honest version — including the things I got wrong.

The main writeup is in the [README](README.md). This is the longer version, with the reasoning behind each choice.

---

# What Terraform is, in one paragraph

Normally I'd build things on AWS by clicking around in a web console — create a network here, launch a server there. Terraform lets me write all of that down in text files instead. I describe what I want, and Terraform builds it. Change the file, run it again, and it updates only what changed. Delete everything and run it again, and I get the exact same setup back.

That's the whole point of this project. I'd already built this by hand. This time I wrote it down as code.

---

# Decisions

## 1 — Where Terraform keeps its memory

Terraform needs to remember what it built. If it forgets, it will build a second copy of everything.

It keeps that memory in a file. By default that file sits on my laptop.

**That's risky for two reasons.** If I lost the file, Terraform would forget everything it created — and I'd be left with servers running in AWS that I could no longer manage or shut down. And if two people run Terraform at the same time, they both write to that file at once and it gets corrupted.

So I put the memory file in cloud storage (S3) instead of on my laptop. It's encrypted, it's backed up, and Terraform locks it while it's being used so nobody else can touch it at the same time.

**What I gave up:** I had to create that storage bucket by hand, before Terraform could run at all. Terraform can't create the bucket that holds its own memory — bit of a chicken and egg thing. One-time manual step, and I accepted it because the problem it prevents is the kind I couldn't recover from.

---

## 2 — How the memory file gets locked

There are two ways to stop two people writing to the memory file at the same time. The older way uses a separate AWS database table. The newer way lets the storage bucket handle it by itself.

Most guides still say to use the separate table. I did that first — then Terraform warned me it's being phased out, because the storage bucket can now do it natively.

So I switched. One less thing to create, one less thing that can break.

**What I gave up:** most existing setups in companies still use the older approach, so I made sure I understand both. If I join a team using the old way, I'll know exactly what it's doing and why.

---

## 3 — Keeping the code in one place

Terraform lets me split my code into reusable chunks. That's useful when there are several environments — say a test setup and a live setup — and the same code gets reused for both.

I have one environment. Splitting it up would just mean jumping between more files to find one thing. So I kept it flat and readable.

**What I gave up:** if I add a test environment later, I'll have to restructure it. That's fine.

---

## 4 — Labelling everything automatically

Every single thing Terraform creates gets a label saying "Terraform made this."

That turned out to be more useful than I expected. Right after my first run, I looked at the AWS console and saw two networks, twelve subnets — twice what I'd built. My old hand-built version was still sitting there alongside the new one.

The label was the only reliable way to tell which was which.

In the manual build, labelling was inconsistent because I had to remember to do it every single time. Now it's automatic.

---

## 5 — How the security rules point at each other

Security groups are like bouncers. Each one decides who's allowed in.

The normal way to write a rule is by IP address: "let in anything coming from this address." But the load balancer's address changes — AWS moves it around. A rule based on an address would quietly stop working.

So instead, each rule points at the *identity* of the thing above it:

```hcl
security_groups = [aws_security_group.alb.id]
```

That says: **"let in whatever is wearing the load balancer's badge."** Not an address. An identity.

The chain looks like this:

```
Internet  →  ALB  →  Servers  →  Database
```

Each layer only accepts traffic from the one directly above it. The database will not accept a connection from anything except the servers. Not because a rule blocks the internet — because there's no path at all.

And every new server the system launches automatically gets the right badge, so it's covered the moment it exists.

---

## 6 — Which server image to use

Every server needs an operating system image to boot from. I could either pin a specific one, or ask for "the latest."

I asked for the latest. That way it always has the newest security patches.

**What I gave up:** "the latest" can change without warning. That's not hypothetical — **it caused Problem 6 below.** For a real production system I'd pin a specific tested image and update it deliberately.

---

# Problems I hit

## 1 — Downloaded the wrong version of Terraform

Grabbed the Mac version by mistake. The file wouldn't run on Windows and the terminal just said "command not found."

Then I found the correct Windows file was buried in a subfolder, in a place the computer doesn't look. Moved it to the right place. Fixed.

---

## 2 — Warning about the old locking method

Terraform started up fine but warned me the locking approach I'd used is being phased out. Switched to the newer one and reran it. Clean.

---

## 3 — The website wouldn't load, and it wasn't AWS's fault

Everything came up healthy. But when I put the URL in my browser, it just hung and timed out.

Turned out the browser had quietly changed my `http://` to `https://`. My setup only listens on the plain HTTP port — nothing is listening on the secure one. So the connection just sat there waiting for a reply that would never come.

Not an infrastructure bug. A browser default.

But it's exactly why a real production site needs proper HTTPS — with a certificate and a redirect. I left it out here because HTTPS needs a domain name I'd have to buy, which was outside what I wanted to spend on this.

Known gap, on purpose.

---

## 4 — Something already existed that shouldn't have

Terraform stopped partway through with:

```
Error: DBSubnetGroupAlreadyExists
```

There was a leftover piece from my old hand-built version still sitting in AWS. It existed, but nothing was managing it — an orphan.

Two options: delete it, or tell Terraform to adopt it. I deleted it, because I wanted everything owned by Terraform and the orphan had no reason to survive.

But adopting it is the right answer when it *can't* be deleted — a live production database, for instance. That's how existing infrastructure gets brought under management without recreating it.

**Also learned:** Terraform doesn't undo its work when it fails. The eight things it had already created stayed created. When I ran it again, it just picked up where it stopped.

---

## 5 — Terraform said it worked. The running servers disagreed.

I updated the server template to give servers permission to be accessed remotely. Terraform said it succeeded.

But I still couldn't connect to the servers.

The template is a **blueprint**. Changing it only affects servers created *from that point onwards*. The two servers already running were built from the old blueprint and still had no permission.

Terraform wasn't lying — it *had* updated the blueprint. Nothing had told the system to rebuild the servers using it.

Fixed it by telling the system to automatically replace its servers whenever the blueprint changes, one at a time so the site never goes down.

**Lesson: "Terraform said it worked" is not the same as "the running servers reflect it."**

---

## 6 — The remote access agent wasn't installed

Fresh server. Still couldn't connect remotely. And this time the permissions *were* correct, so it wasn't the same problem as before.

I pulled the server's startup log. Everything had worked — the web server installed, the database tools installed, no errors at all, finished in 44 seconds. So the server clearly had a working internet connection.

Then I searched the log for the remote access agent. **Nothing.** It wasn't starting, it wasn't failing — it just wasn't there.

**The cause:** when I asked for "the latest server image," my search was too broad. It also matched a stripped-down version of the image — and that stripped-down version doesn't include the remote access agent. Terraform had quietly picked it.

Two fixes: I narrowed the search so it only matches the full image, and I installed the agent explicitly at startup so it doesn't depend on which image comes back.

**The way I found it is the point.** The log said everything *succeeded*. It was the **absence** of any mention of the agent that told me what was wrong. Nothing errored.

---

## 7 — Two failed health checks at startup, every time

The load balancer checks whether each server is alive by requesting the homepage. The first two checks come back as errors, then everything goes fine.

Here's why. My startup script installs the web server, then a few other things, and *finally* writes the homepage file. In between, the web server is running but has no page to serve. So it returns an error.

That's exactly what the **startup grace period** is for. It tells the system: "ignore health checks for the first five minutes — this server is still booting."

Without it, the system would see the error, decide the server is broken, shut it down, and start a new one — which would also error while booting, and also get shut down. **Forever.** The site would never come up.

Most people set a grace period because they were told to. I can point at the exact errors in my own logs that it's covering.

---

# What the Terraform build fixed permanently

## The 502 error can't happen again

In my hand-built version, I let the system auto-create the load balancer. AWS attached the **wrong security badge** to it. The chain broke. Every server was marked unhealthy and the site returned an error.

I spent time checking the wrong things — the web server was fine, the network routes were fine, the security rules themselves were fine. The problem was which badge the load balancer was *wearing* — which in the AWS console is a completely different screen from where I'd written the rules. Nothing connects the two.

In Terraform, it's all in one file:

```hcl
resource "aws_security_group" "app" {
  ingress {
    security_groups = [aws_security_group.alb.id]   # only the load balancer can talk to me
  }
}

resource "aws_lb" "main" {
  security_groups = [aws_security_group.alb.id]     # the load balancer says which badge it wears
}
```

The load balancer **cannot exist** without saying which badge it wears. It's required. If I gave it the wrong one, the servers' rule would then be pointing at a badge that nobody is wearing — and I'd see that in the code, before anything got built.

It isn't stopped by a validation rule. It's stopped because **the wiring is written down in one place**, instead of being spread across three different screens.

**Both servers came up healthy on the first run. No error. Nothing to debug.**

---

## The database client fix is now permanent

In the manual build, installing the database client tool failed. The command everyone uses — `dnf install mysql` — just doesn't work on this version of Linux. The package is called something else entirely: `mariadb105`.

That cost me real time to work out.

It's now written into the server startup script. **Every server that ever gets created installs the right thing automatically.** Nobody — including future me — has to figure it out again.

I also added one line that makes the script **stop immediately if anything fails**. Without it, a failed install would be ignored, the server would boot "successfully" with no web server on it, and the health check would fail with nothing obvious to point at.

---

## Logging — what would have found the 502 in thirty seconds

The web server logs now get shipped off the machine and into AWS's logging service. Here's what they look like:

```
10.0.2.226 - - "GET / HTTP/1.1" 403 191 "ELB-HealthChecker/2.0"
10.0.1.190 - - "GET / HTTP/1.1" 403 191 "ELB-HealthChecker/2.0"
10.0.2.226 - - "GET / HTTP/1.1" 200 69  "ELB-HealthChecker/2.0"
10.0.1.190 - - "GET / HTTP/1.1" 200 69  "ELB-HealthChecker/2.0"
```

I can watch the load balancer checking on the server, getting an error while it's still starting up, then getting a success once it's ready.

**In my hand-built version, these lines would not have existed at all.** The wrong badge meant the load balancer never reached the server. The log would have been completely empty.

And that's the diagnostic:

| What the log shows | What it means |
|---|---|
| **Nothing at all** | The check isn't reaching the server → **security problem** |
| **Errors** | It reaches the server, but the app is broken |
| **Successes** | Working |

I had no logging in the manual build, so I couldn't tell those apart. I checked the web server, then the network routes, then the security rules, one at a time.

I also turned on network-level logging, which records every connection attempt and whether it was allowed or blocked. That would have shown the load balancer's check being **blocked** — the answer, immediately.

---

# Verified

## The site came up on the first try

The URL served the page. The server shown was one sitting in a private part of the network, with no public address at all — reachable only through the load balancer.

Both servers were healthy on the **first run**. Same architecture, same services as the hand-built version. Different outcome — because the wiring is declared in one file, where a mistake is visible before anything gets built, instead of after.

---

## The whole chain, end to end

I connected to a server that has **no password, no key file, and no open door to the internet**. The way this works is that the server reaches *out* to AWS, and AWS relays my session back through that connection. I never connect *to* the machine.

From inside it, I read the database password from AWS's secure password store. The server has **no credentials stored on it at all** — it gets temporary ones, automatically, that expire.

Then I connected to the database:

```
Welcome to the MariaDB monitor.
Server version: 8.4.9

SHOW DATABASES;
appdb, information_schema, mysql, performance_schema, sys
```

**One test, six things proven:**

- Remote access works, with no key and no open port
- The permissions are correctly scoped — the server can read exactly one secret, and nothing else
- The security chain lets the server reach the database
- The database client was **already installed** — the fix is baked in
- The database is running
- The server has working internet

The database client being there without me doing anything is the point. In the manual build, that cost me time. It doesn't any more.

---

## Destroy it, rebuild it

```
terraform destroy   ->  Destroy complete! Resources: 47 destroyed.
terraform apply     ->  Apply complete! Resources: 47 added.
```

Everything came back. The network, all six subnets, the load balancer, the servers, the database with its standby copy, all the permissions, all the logging.

**New IDs. Identical setup.**

```
Load balancer before:  three-tier-alb-1816193923...
Load balancer after:   three-tier-alb-528708595...
Network before:        vpc-063bdc222855d57f7
Network after:         vpc-0ee44836ee148902c
```

**Zero clicks. Zero manual steps. Zero bugs I had to solve again.**

Every problem I'd already fixed stayed fixed. The database client, the remote access agent, the security chain, the permissions — I didn't debug a single one of them a second time.

And **nobody typed a password.** Terraform generated a fresh random one, gave it to the database, and put it in the secure store. The app reads it automatically. I don't know what it is and I don't need to.

---

# The numbers

## By layer

| Layer | Things created | Time |
|---|---|---|
| Network (subnets, gateways, routing) | 18 | 2m 39s |
| Security rules | 3 | seconds |
| Servers + load balancer | 6 | 3m 10s |
| Database + permissions | 12 | 16m 32s |
| Logging | 11 | ~2m |
| **Total** | **47** | |

**Where the time actually goes:**

- **The database is 16 minutes on its own.** By far the slowest thing. AWS builds the main copy, then a standby copy in a second location, then syncs them.
- **The load balancer is 3 minutes.** They're just slow.
- **The internet gateway is about 90 seconds** of the network layer's 2m39s.

Before I built anything, Terraform predicted it would create exactly 18 things for the network layer. I'd counted 18 by hand. They matched. Free correctness check.

## Full teardown and rebuild

| | |
|---|---|
| Destroy everything | ~13 min |
| Build it all back | **15 min 36 sec** |
| Clicks required | 0 |
| Bugs re-debugged | 0 |

---

# Setup

- Terraform v1.15.8
- AWS provider v5.100.0
- Region: us-east-1
- Memory file stored in S3, encrypted, with locking

---

# Known gaps

## What's protected

- **Three layers of security rules.** Each layer only accepts traffic from the one above it. The database will not accept a connection from anything except the servers.
- **The database has no public address.** There is no route from the internet to it — not because a rule blocks it, but because no path exists.
- **No open doors.** There is no SSH port open anywhere. Remote access works by the server reaching *out*, so there's nothing to attack from the outside.
- **The database password is never written down.** Terraform generates it, gives it to the database, and stores it in AWS's secure store. It's not in the code and it's not in this repository.
- **Terraform's memory file is encrypted and never uploaded to GitHub** — because it contains that password, and there's no way around that. I secured it before I had a secret to put in it.
- **Everything is logged.** Every network connection, and every change anyone makes to the AWS account.
- **The database is encrypted** where it sits on disk.

## What's missing, and why

- **No HTTPS.** Traffic between a browser and the load balancer isn't encrypted. Anyone on the network path could read it. HTTPS needs a domain name I'd have to buy — outside what I wanted to spend on this. **This is the one I'd add first.**

- **The database isn't protected from deletion.** I turned that protection off so I could tear everything down while testing. Right now, deleting one block of code would destroy the database — no confirmation, no backup. In production, that would be locked.

- **The password never changes.** AWS can rotate it automatically. I didn't turn that on. Mild — the password is random, never chosen by a human, and every time it's read it gets logged.

- **No threat detection.** AWS has services for this. At this scale, each one would cost more than the entire rest of the project.

- **I can read the database password.** My own account has permission. In a real company, engineers shouldn't be able to read production passwords at all — only the application should. Debugging happens through logs, not by reading passwords.

That last one is worth being precise about. **I can read it because I have permission — and every time I do, it's logged.** That's *access control*, not *knowledge*. Take the permission away and I lose access immediately, without changing the password.

---

## Why there's no automated pipeline

Right now I run Terraform from my own laptop. In a real team that's wrong. It should run automatically, after somebody has reviewed the change.

**But automatically *applying* infrastructure changes on every push is worse than having no pipeline at all.**

Here's why. A single bad line can delete a database, with nobody having looked at what was about to happen. A broken app can be undone in minutes. A deleted database cannot.

The right way: someone proposes a change → the system automatically works out what it *would* do → that gets posted for a human to read → and only after they approve does anything actually happen.

**The human reading it is the entire safety mechanism.** It's not an obstacle. It's the point.

This is the biggest gap in the project, and I know it.
