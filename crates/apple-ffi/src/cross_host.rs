//! Agents reaching other hosts, relayed by this device ([`CrossHostRelay`]).
//!
//! The app makes one relay, adds every host it knows (owner hosts with their
//! [`DaemonClient`], guest and plain-SSH hosts by name, which are never targets), keeps the
//! owner's per-pair switches in it, and shows the [`CrossHostCard`]s it sends to a
//! [`CrossHostListener`]. Owner connections that relay must be made with
//! `ConnectOptions.cross_host = true`.

use std::sync::Arc;

use client_core::proto::{self, RequestId};

use crate::client::DaemonClient;

/// What a relayed tool does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CrossHostVerb {
    Read,
    Open,
    Input,
    Close,
}

impl From<proto::CrossHostVerb> for CrossHostVerb {
    fn from(verb: proto::CrossHostVerb) -> Self {
        match verb {
            proto::CrossHostVerb::Read => Self::Read,
            proto::CrossHostVerb::Open => Self::Open,
            proto::CrossHostVerb::Input => Self::Input,
            proto::CrossHostVerb::Close => Self::Close,
        }
    }
}

/// A request that needs the owner's answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CrossHostCard {
    /// The asking host's id (as added); answer with it and `request_id`.
    pub from: String,
    pub request_id: u64,
    /// `Claude`.
    pub agent: String,
    /// The asking agent's pane on its host.
    pub pane_id: u64,
    pub from_name: String,
    /// The target host's id (as added).
    pub to: String,
    pub to_name: String,
    pub tool: String,
    pub verb: CrossHostVerb,
    /// The call in words, from its arguments: `run $ npm test`.
    pub action: String,
    /// `Claude on mac wants to run $ npm test on ops`.
    pub title: String,
    /// A guest drives the asking pane: their name.
    pub guest_driving: Option<String>,
    pub expires_at_ms: u64,
}

impl From<client_core::CrossHostCard> for CrossHostCard {
    fn from(card: client_core::CrossHostCard) -> Self {
        let title = card.title();
        Self {
            from: card.key.from,
            request_id: card.key.id.0,
            agent: card.agent,
            pane_id: card.pane_id.0,
            from_name: card.from_name,
            to: card.to,
            to_name: card.to_name,
            tool: card.tool,
            verb: card.verb.into(),
            action: card.action,
            title,
            guest_driving: card.guest_driving,
            expires_at_ms: card.expires_at.0,
        }
    }
}

/// An agent's standing yes on another host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StandingAllow {
    pub from: String,
    pub from_name: String,
    pub to: String,
    pub to_name: String,
    pub pane_id: u64,
    pub agent: String,
    /// Everything ("Allow all for this agent"); else reads after an "Allow once".
    pub all: bool,
}

impl From<client_core::StandingAllow> for StandingAllow {
    fn from(allow: client_core::StandingAllow) -> Self {
        Self {
            from: allow.from,
            from_name: allow.from_name,
            to: allow.to,
            to_name: allow.to_name,
            pane_id: allow.pane_id.0,
            agent: allow.agent,
            all: allow.scope == client_core::StandingScope::All,
        }
    }
}

/// The owner's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CrossHostChoice {
    AllowOnce,
    /// Everything this agent asks on that host until its pane closes.
    AllowAgent,
    Deny,
}

impl From<CrossHostChoice> for client_core::CrossHostChoice {
    fn from(choice: CrossHostChoice) -> Self {
        match choice {
            CrossHostChoice::AllowOnce => Self::AllowOnce,
            CrossHostChoice::AllowAgent => Self::AllowAgent,
            CrossHostChoice::Deny => Self::Deny,
        }
    }
}

/// Receives what the relay tells the app; implemented in Swift. Called on a runtime thread.
/// Return quickly.
#[uniffi::export(foreign)]
pub trait CrossHostListener: Send + Sync {
    /// A request needs the owner's answer.
    fn on_card(&self, card: CrossHostCard);
    /// It no longer does: answered here or elsewhere, expired or withdrawn.
    fn on_card_closed(&self, from: String, request_id: u64);
    /// The standing yeses changed.
    fn on_standing(&self, allows: Vec<StandingAllow>);
}

struct Forward(Arc<dyn CrossHostListener>);

impl client_core::CrossHostListener for Forward {
    fn on_cross_host_event(&self, event: client_core::CrossHostEvent) {
        match event {
            client_core::CrossHostEvent::Card(card) => self.0.on_card(card.into()),
            client_core::CrossHostEvent::CardClosed(key) => {
                self.0.on_card_closed(key.from, key.id.0);
            }
            client_core::CrossHostEvent::Standing(allows) => {
                self.0
                    .on_standing(allows.into_iter().map(Into::into).collect());
            }
        }
    }
}

/// Relays agents' calls between this device's hosts.
#[derive(uniffi::Object)]
pub struct CrossHostRelay {
    inner: client_core::CrossHostRelay,
}

#[uniffi::export]
impl CrossHostRelay {
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn CrossHostListener>) -> Arc<Self> {
        Arc::new(Self {
            inner: client_core::CrossHostRelay::new(Arc::new(Forward(listener))),
        })
    }

    /// A host paired as owner, with its connection (made with `cross_host`).
    pub fn add_owner_host(&self, id: String, name: String, client: Arc<DaemonClient>) {
        self.inner.add_host(client_core::RelayHost::owner(
            id,
            name,
            Arc::clone(&client.inner),
        ));
    }

    /// A host joined as a guest: listed, never a target.
    pub fn add_guest_host(&self, id: String, name: String) {
        self.inner.add_host(client_core::RelayHost::guest(id, name));
    }

    /// A host reached over plain SSH: listed, never a target until its helper is installed.
    pub fn add_ssh_host(&self, id: String, name: String) {
        self.inner
            .add_host(client_core::RelayHost::ssh_only(id, name));
    }

    pub fn remove_host(&self, id: String) {
        self.inner.remove_host(&id);
    }

    /// "Agents on `from` may reach `to`". Off ends every standing yes for the pair.
    pub fn set_pair(&self, from: String, to: String, enabled: bool) {
        self.inner.set_pair(&from, &to, enabled);
    }

    pub fn pair_enabled(&self, from: String, to: String) -> bool {
        self.inner.pair_enabled(&from, &to)
    }

    /// Ends the pair's standing yeses, keeping it on.
    pub fn end_allows(&self, from: String, to: String) {
        self.inner.end_allows(&from, &to);
    }

    pub fn answer(&self, from: String, request_id: u64, choice: CrossHostChoice) {
        let key = client_core::CrossHostCardKey {
            from,
            id: RequestId(request_id),
        };
        self.inner.answer(&key, choice.into());
    }

    pub fn standing(&self) -> Vec<StandingAllow> {
        self.inner.standing().into_iter().map(Into::into).collect()
    }
}
