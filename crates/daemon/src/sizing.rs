use std::cmp::Reverse;
use std::collections::BTreeMap;

use proto::{PaneActivity, PaneSize, PrincipalId, SizePolicy};

use crate::core::ConnId;
use crate::mp::Authz;

#[derive(Debug, thiserror::Error)]
#[error("terminal grids need nonzero columns and rows")]
pub(crate) struct EmptyGrid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SizeChoice {
    pub owner: Option<(ConnId, PrincipalId)>,
    pub size: PaneSize,
}

struct Request {
    authz: Authz,
    size: Option<PaneSize>,
    activity: PaneActivity,
    explicit_activity: bool,
    active_order: u64,
    input_order: u64,
}

#[derive(Default)]
pub(crate) struct Sizing {
    policy: Option<SizePolicy>,
    requests: BTreeMap<ConnId, Request>,
    order: u64,
    desired: Option<SizeChoice>,
}

impl Sizing {
    pub fn policy(&self) -> SizePolicy {
        self.policy.unwrap_or(SizePolicy::LastActive)
    }

    pub fn set_policy(&mut self, policy: SizePolicy) -> Result<(), EmptyGrid> {
        if let SizePolicy::Fixed { cols, rows } = policy
            && (cols == 0 || rows == 0)
        {
            return Err(EmptyGrid);
        }
        self.policy = Some(policy);
        Ok(())
    }

    fn request(&mut self, conn: ConnId, authz: &Authz, activity: PaneActivity) -> &mut Request {
        self.requests.entry(conn).or_insert_with(|| Request {
            authz: authz.clone(),
            size: None,
            activity,
            explicit_activity: false,
            active_order: 0,
            input_order: 0,
        })
    }

    pub fn set_size(
        &mut self,
        conn: ConnId,
        authz: &Authz,
        size: PaneSize,
        initial_activity: PaneActivity,
    ) -> Result<(), EmptyGrid> {
        if size.cols == 0 || size.rows == 0 {
            return Err(EmptyGrid);
        }
        self.request(conn, authz, initial_activity).size = Some(size);
        Ok(())
    }

    pub fn view_activity(&mut self, conn: ConnId, authz: &Authz, activity: PaneActivity) {
        if self.request(conn, authz, activity).explicit_activity {
            return;
        }
        self.activity(conn, authz, activity);
    }

    pub fn explicit_activity(&mut self, conn: ConnId, authz: &Authz, activity: PaneActivity) {
        let request = self.request(conn, authz, activity);
        if request.explicit_activity && request.activity == activity {
            return;
        }
        request.explicit_activity = true;
        self.activity(conn, authz, activity);
    }

    fn activity(&mut self, conn: ConnId, authz: &Authz, activity: PaneActivity) {
        self.order = self.order.saturating_add(1);
        let order = self.order;
        let request = self.request(conn, authz, activity);
        request.activity = activity;
        if activity == PaneActivity::Active {
            request.active_order = order;
        }
    }

    pub fn input(&mut self, conn: ConnId) {
        self.order = self.order.saturating_add(1);
        if let Some(request) = self.requests.get_mut(&conn)
            && request.activity == PaneActivity::Active
        {
            request.input_order = self.order;
            request.active_order = self.order;
        }
    }

    pub fn is_active(&self, conn: ConnId) -> bool {
        self.requests
            .get(&conn)
            .is_some_and(|request| request.activity == PaneActivity::Active)
    }

    pub fn remove(&mut self, conn: ConnId) {
        self.requests.remove(&conn);
    }

    pub fn choose(&self, eligible: impl Fn(&Authz) -> bool) -> Option<SizeChoice> {
        let policy = self.policy();
        if let SizePolicy::Fixed { cols, rows } = policy {
            return Some(SizeChoice {
                owner: None,
                size: PaneSize {
                    cols,
                    rows,
                    width_px: 0,
                    height_px: 0,
                },
            });
        }
        let candidates = || {
            self.requests.iter().filter(|(_, request)| {
                request.activity == PaneActivity::Active
                    && request.size.is_some()
                    && eligible(&request.authz)
            })
        };
        if policy == SizePolicy::Smallest {
            let (cols, rows) = candidates().filter_map(|(_, request)| request.size).fold(
                None::<(u16, u16)>,
                |smallest, size| {
                    Some(match smallest {
                        None => (size.cols, size.rows),
                        Some((cols, rows)) => (cols.min(size.cols), rows.min(size.rows)),
                    })
                },
            )?;
            return Some(SizeChoice {
                owner: None,
                size: PaneSize {
                    cols,
                    rows,
                    width_px: 0,
                    height_px: 0,
                },
            });
        }
        let (conn, request) = candidates().max_by_key(|(conn, request)| {
            let order = match policy {
                SizePolicy::LastInput | SizePolicy::FollowLease => request.input_order,
                _ => request.active_order,
            };
            (order, Reverse(**conn))
        })?;
        Some(SizeChoice {
            owner: Some((*conn, request.authz.actor.principal)),
            size: request.size?,
        })
    }

    pub fn update_choice(&mut self, choice: Option<SizeChoice>) -> bool {
        let changed = self.desired != choice;
        self.desired = choice;
        changed
    }
}

#[cfg(test)]
mod tests {
    use proto::{Actor, DeviceId};

    use super::*;

    fn authz(device: u8) -> Authz {
        Authz::owner(Actor {
            principal: PrincipalId([1; 16]),
            device: DeviceId([device; 32]),
        })
    }

    fn size(cols: u16, rows: u16) -> PaneSize {
        PaneSize {
            cols,
            rows,
            width_px: 0,
            height_px: 0,
        }
    }

    fn two_clients() -> Sizing {
        let mut sizing = Sizing::default();
        sizing
            .set_size(1, &authz(1), size(160, 40), PaneActivity::Active)
            .unwrap();
        sizing.view_activity(1, &authz(1), PaneActivity::Active);
        sizing
            .set_size(2, &authz(2), size(45, 20), PaneActivity::Active)
            .unwrap();
        sizing.view_activity(2, &authz(2), PaneActivity::Active);
        sizing
    }

    #[test]
    fn background_hands_over_and_inactive_resizes_only_update_the_saved_request() {
        let mut sizing = two_clients();
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(45, 20));
        sizing.explicit_activity(2, &authz(2), PaneActivity::Inactive);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
        sizing
            .set_size(2, &authz(2), size(60, 25), PaneActivity::Active)
            .unwrap();
        sizing.input(2);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
        sizing.view_activity(2, &authz(2), PaneActivity::Active);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
        sizing.explicit_activity(2, &authz(2), PaneActivity::Active);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(60, 25));
    }

    #[test]
    fn last_input_and_latest_active_choose_independently() {
        let mut sizing = two_clients();
        sizing.input(1);
        sizing.explicit_activity(2, &authz(2), PaneActivity::Active);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(45, 20));
        sizing.set_policy(SizePolicy::LastInput).unwrap();
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
    }

    #[test]
    fn repeated_activity_does_not_steal_another_active_clients_claim() {
        let mut sizing = two_clients();
        sizing.explicit_activity(2, &authz(2), PaneActivity::Active);
        sizing.input(1);
        sizing.explicit_activity(2, &authz(2), PaneActivity::Active);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
        sizing.set_policy(SizePolicy::FollowLease).unwrap();
        sizing.input(2);
        assert_eq!(
            sizing
                .choose(|candidate| candidate.actor.device == authz(1).actor.device)
                .unwrap()
                .size,
            size(160, 40)
        );
    }

    #[test]
    fn fixed_and_smallest_do_not_depend_on_the_last_sender() {
        let mut sizing = two_clients();
        assert!(
            sizing
                .set_size(2, &authz(2), size(0, 20), PaneActivity::Active)
                .is_err()
        );
        sizing.set_policy(SizePolicy::Smallest).unwrap();
        assert_eq!(
            sizing.choose(|_| true).unwrap(),
            SizeChoice {
                owner: None,
                size: size(45, 20)
            }
        );
        sizing
            .set_policy(SizePolicy::Fixed { cols: 90, rows: 30 })
            .unwrap();
        sizing.input(2);
        sizing.remove(1);
        sizing.remove(2);
        assert_eq!(
            sizing.choose(|_| false).unwrap(),
            SizeChoice {
                owner: None,
                size: size(90, 30)
            }
        );
        assert!(
            sizing
                .set_policy(SizePolicy::Fixed { cols: 0, rows: 30 })
                .is_err()
        );
        assert_eq!(sizing.policy(), SizePolicy::Fixed { cols: 90, rows: 30 });
    }

    #[test]
    fn departing_and_ineligible_clients_cannot_remain_the_sizer() {
        let mut sizing = two_clients();
        assert_eq!(
            sizing
                .choose(|candidate| candidate.actor.device == authz(1).actor.device)
                .unwrap()
                .size,
            size(160, 40)
        );
        sizing.remove(2);
        assert_eq!(sizing.choose(|_| true).unwrap().size, size(160, 40));
        sizing.explicit_activity(1, &authz(1), PaneActivity::Inactive);
        assert!(sizing.choose(|_| true).is_none());
    }
}
