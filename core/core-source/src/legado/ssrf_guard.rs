//! SSRF (Server-Side Request Forgery) guard for outbound HTTP requests.
//!
//! Validates that URLs used by JS bridge functions and the rule-engine HTTP
//! client target only public hosts over http/https. Private, loopback,
//! link-local, CGNAT, multicast, and cloud-metadata addresses are rejected.
//!
//! Reference: Kotlin `isPrivateHost` at `flutter_app/android/.../MainActivity.kt:92-103`.

use std::cell::Cell;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

// Thread-local bypass for tests that use localhost mock servers.
thread_local! {
    static SSRF_BYPASS: Cell<bool> = const { Cell::new(cfg!(test)) };
}

/// Disable SSRF checks on the current thread. Used by tests with httpmock.
pub fn bypass_for_test(enabled: bool) {
    SSRF_BYPASS.with(|c| c.set(enabled));
}

#[derive(Debug, Clone)]
pub enum SsrfError {
    ForbiddenScheme(String),
    PrivateHost(String),
    InvalidUrl(String),
}

impl std::fmt::Display for SsrfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ForbiddenScheme(s) => write!(f, "forbidden scheme: {s}"),
            Self::PrivateHost(h) => write!(f, "private/reserved host: {h}"),
            Self::InvalidUrl(u) => write!(f, "invalid URL: {u}"),
        }
    }
}

impl std::error::Error for SsrfError {}

/// Returns `Ok(())` if the URL is safe for outbound fetch (http/https + public host).
pub fn is_url_safe_for_fetch(url: &str) -> Result<(), SsrfError> {
    if SSRF_BYPASS.with(|c| c.get()) {
        return Ok(());
    }
    let parsed = url::Url::parse(url).map_err(|_| SsrfError::InvalidUrl(url.to_string()))?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(SsrfError::ForbiddenScheme(scheme.to_string()));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| SsrfError::InvalidUrl(url.to_string()))?;
    if is_private_host(host) {
        return Err(SsrfError::PrivateHost(host.to_string()));
    }
    Ok(())
}

/// Returns `true` if the host resolves to a private/reserved address space.
pub fn is_private_host(host: &str) -> bool {
    let h = host.to_ascii_lowercase();
    // Well-known local hostnames
    if h == "localhost" || h == "ip6-localhost" || h == "ip6-loopback" {
        return true;
    }
    // Cloud metadata endpoints
    if h == "metadata.google.internal" || h == "169.254.169.254" {
        return true;
    }
    // Try parse as IP literal
    if let Ok(ip) = h.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    // Bracketed IPv6 (defensive; url::Url strips brackets)
    let stripped = h
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(&h);
    if let Ok(ip) = stripped.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    false
}

fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()          // 127.0.0.0/8
            || v4.is_private()        // 10/8, 172.16/12, 192.168/16
            || v4.is_link_local()     // 169.254.0.0/16
            || v4.is_unspecified()    // 0.0.0.0
            || v4.is_broadcast()      // 255.255.255.255
            || v4.is_multicast()      // 224.0.0.0/4
            || is_cgnat(v4)           // 100.64.0.0/10
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()          // ::1
            || v6.is_unspecified()    // ::
            || v6.is_multicast()      // ff00::/8
            || is_ipv6_link_local(v6) // fe80::/10
            || is_ipv6_unique_local(v6) // fc00::/7
            || is_ipv4_mapped_private(v6) // ::ffff:10.x.x.x etc.
        }
    }
}

fn is_cgnat(v4: Ipv4Addr) -> bool {
    let [a, b, ..] = v4.octets();
    a == 100 && (b & 0xC0) == 64 // 100.64.0.0/10
}

fn is_ipv6_link_local(v6: Ipv6Addr) -> bool {
    let segs = v6.segments();
    (segs[0] & 0xFFC0) == 0xFE80
}

fn is_ipv6_unique_local(v6: Ipv6Addr) -> bool {
    let segs = v6.segments();
    (segs[0] & 0xFE00) == 0xFC00
}

fn is_ipv4_mapped_private(v6: Ipv6Addr) -> bool {
    if let Some(v4) = v6.to_ipv4_mapped() {
        is_private_ip(IpAddr::V4(v4))
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SSRF guard tests must disable the test bypass to actually test the guard.
    fn with_ssrf_enabled<F: FnOnce()>(f: F) {
        bypass_for_test(false);
        f();
        bypass_for_test(true);
    }

    #[test]
    fn test_ssrf_public_http_ok() {
        with_ssrf_enabled(|| {
            assert!(is_url_safe_for_fetch("http://example.com/path").is_ok());
        });
    }

    #[test]
    fn test_ssrf_public_https_ok() {
        with_ssrf_enabled(|| {
            assert!(is_url_safe_for_fetch("https://cdn.example.com/font.ttf").is_ok());
        });
    }

    #[test]
    fn test_ssrf_forbidden_scheme_file() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("file:///etc/passwd"),
                Err(SsrfError::ForbiddenScheme(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_forbidden_scheme_ftp() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("ftp://internal/data"),
                Err(SsrfError::ForbiddenScheme(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_loopback_ipv4() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://127.0.0.1:8080/api"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_loopback_ipv6() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://[::1]/api"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_localhost() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://localhost/secret"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_rfc1918_10() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://10.0.0.1/internal"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_rfc1918_172() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://172.16.0.1/internal"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_rfc1918_192() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://192.168.1.1/router"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_link_local() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://169.254.169.254/metadata"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_cgnat() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://100.64.0.1/internal"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_multicast() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://224.0.0.1/"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_metadata_google() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://metadata.google.internal/computeMetadata/v1/"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_ipv6_unique_local() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("http://[fc00::1]/"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_ipv4_mapped_private() {
        with_ssrf_enabled(|| {
            // ::ffff:127.0.0.1
            assert!(matches!(
                is_url_safe_for_fetch("http://[::ffff:127.0.0.1]/"),
                Err(SsrfError::PrivateHost(_))
            ));
        });
    }

    #[test]
    fn test_ssrf_invalid_url() {
        with_ssrf_enabled(|| {
            assert!(matches!(
                is_url_safe_for_fetch("not a url at all"),
                Err(SsrfError::InvalidUrl(_))
            ));
        });
    }
}
