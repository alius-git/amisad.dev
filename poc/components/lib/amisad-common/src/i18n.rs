// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
//! Catalog-backed problem messages. Protocol codes are never translated.
use crate::json;
use std::sync::OnceLock;

fn catalogs() -> &'static [json::Json; 4] {
    static CATALOGS: OnceLock<[json::Json; 4]> = OnceLock::new();
    CATALOGS.get_or_init(|| [
        include_str!("../locales/en-US.json"),
        include_str!("../locales/pt-BR.json"),
        include_str!("../locales/zh-CN.json"),
        include_str!("../locales/he-IL.json"),
    ].map(|text| json::parse(text).expect("validated message catalog")))
}

pub(crate) fn contains(code: &str) -> bool {
    catalogs()[0].get("messages").and_then(|messages| messages.get(code)).is_some()
}

pub(crate) fn message(locale: &str, code: &str) -> String {
    let index = match locale { "pt-BR" => 1, "zh-CN" => 2, "he-IL" => 3, _ => 0 };
    catalogs()[index].get("messages").and_then(|messages| messages.get(code))
        .and_then(|entry| entry.str_of("text")).unwrap_or(code).to_string()
}

pub(crate) fn negotiate(header: &str) -> String {
    let mut choices: Vec<_> = header.split(',').enumerate().filter_map(|(order, item)| {
        let mut parts = item.trim().split(';');
        let tag = parts.next()?.trim().to_ascii_lowercase();
        let mut quality = 1.0f32;
        for parameter in parts {
            let (name, value) = parameter.trim().split_once('=')?;
            if name.trim() == "q" { quality = value.trim().parse().ok()?; }
        }
        if !(0.0 < quality && quality <= 1.0) { return None; }
        let language = tag.split('-').next()?;
        let locale = match language {
            "pt" => "pt-BR", "zh" => "zh-CN", "he" => "he-IL", "en" | "*" => "en-US", _ => return None,
        };
        Some((quality, order, locale))
    }).collect();
    choices.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    choices.first().map(|choice| choice.2).unwrap_or("en-US").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn languages_follow_preference_and_keep_protocol_codes() {
        assert_eq!(negotiate("fr, he;q=0.8, pt-BR;q=0.4"), "he-IL");
        assert_eq!(negotiate("zh-CN;q=0, en;q=0.2"), "en-US");
        assert_eq!(negotiate("pt;q=NaN, *;q=0.1"), "en-US");
        assert_ne!(message("en-US", "tenant_mismatch"), message("pt-BR", "tenant_mismatch"));
        assert_eq!(message("he-IL", "unknown_protocol_code"), "unknown_protocol_code");
    }
}
