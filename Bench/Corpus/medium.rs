// Deterministic benchmark corpus (seed 2); not meant to compile.
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct Alpha0 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Alpha0 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 56.4_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind1 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe1(k: Kind1) -> String {
    match k {
        Kind1::Small => String::from("small sigma"),
        Kind1::Medium(n) if n > 428 => format!("medium {} over", n),
        Kind1::Medium(n) => format!("medium {}", n),
        Kind1::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind2 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe2(k: Kind2) -> String {
    match k {
        Kind2::Small => String::from("small lambda"),
        Kind2::Medium(n) if n > 2 => format!("medium {} over", n),
        Kind2::Medium(n) => format!("medium {}", n),
        Kind2::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape3 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "delta"
    }
}

struct Square3(f64);

impl Shape3 for Square3 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 4.
pub fn sample4(x: u64, y: u64) -> u64 {
    let v0 = x + 29034 & y;
    v0
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa5 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa5 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 72.98_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect6<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 5)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta7 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta7 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 83.47_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect8<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

pub trait Shape9 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "zeta"
    }
}

struct Square9(f64);

impl Shape9 for Square9 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect10<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

fn parse11(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape12 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square12(f64);

impl Shape12 for Square12 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_13: usize = 59850;
static NAMES_13: [&str; 3] = ["kappa", "gamma", "theta"];

#[cfg(test)]
mod tests13 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_13 < 100_000, "limit {} too big", super::LIMIT_13);
    }
}

pub trait Shape14 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square14(f64);

impl Shape14 for Square14 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 15.
pub fn sample15(x: u64, y: u64) -> u64 {
    let v0 = x + 50331 ^ y;
    let v1 = v0 + 8962 | y;
    v1
}

#[derive(Debug, Copy, Clone)]
enum Kind16 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe16(k: Kind16) -> String {
    match k {
        Kind16::Small => String::from("small gamma"),
        Kind16::Medium(n) if n > 469 => format!("medium {} over", n),
        Kind16::Medium(n) => format!("medium {}", n),
        Kind16::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 17.
pub fn sample17(x: u64, y: u64) -> u64 {
    let v0 = x * 39313 ^ y;
    v0
}

pub trait Shape18 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square18(f64);

impl Shape18 for Square18 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Beta19 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Beta19 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 84.26_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega20 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega20 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 76.14_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape21 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square21(f64);

impl Shape21 for Square21 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 22.
pub fn sample22(x: u64, y: u64) -> u64 {
    let v0 = x + 10253 + y;
    let v1 = v0 | 79581 ^ y;
    let v2 = v1 - 71955 ^ y;
    v2
}

#[derive(Debug, Clone, PartialEq)]
pub struct Lambda23 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Lambda23 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 74.53_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_24: usize = 63395;
static NAMES_24: [&str; 3] = ["lambda", "gamma", "theta"];

#[cfg(test)]
mod tests24 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_24 < 100_000, "limit {} too big", super::LIMIT_24);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind25 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe25(k: Kind25) -> String {
    match k {
        Kind25::Small => String::from("small alpha"),
        Kind25::Medium(n) if n > 606 => format!("medium {} over", n),
        Kind25::Medium(n) => format!("medium {}", n),
        Kind25::Large { width, height } => format!("{}x{}", width, height),
    }
}

const LIMIT_26: usize = 40488;
static NAMES_26: [&str; 3] = ["theta", "lambda", "kappa"];

#[cfg(test)]
mod tests26 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_26 < 100_000, "limit {} too big", super::LIMIT_26);
    }
}

const LIMIT_27: usize = 89622;
static NAMES_27: [&str; 3] = ["kappa", "delta", "kappa"];

#[cfg(test)]
mod tests27 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_27 < 100_000, "limit {} too big", super::LIMIT_27);
    }
}

/// Mixes `x` and `y` for block 28.
pub fn sample28(x: u64, y: u64) -> u64 {
    let v0 = x * 56409 * y;
    let v1 = v0 | 6483 & y;
    let v2 = v1 * 93310 + y;
    let v3 = v2 | 39893 + y;
    v3
}

pub fn collect29<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

fn parse30(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind31 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe31(k: Kind31) -> String {
    match k {
        Kind31::Small => String::from("small alpha"),
        Kind31::Medium(n) if n > 673 => format!("medium {} over", n),
        Kind31::Medium(n) => format!("medium {}", n),
        Kind31::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape32 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square32(f64);

impl Shape32 for Square32 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect33<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

pub trait Shape34 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square34(f64);

impl Shape34 for Square34 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect35<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

pub fn collect36<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma37 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma37 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 62.7_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect38<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 39.
pub fn sample39(x: u64, y: u64) -> u64 {
    let v0 = x ^ 51718 & y;
    let v1 = v0 - 33708 * y;
    let v2 = v1 * 24447 * y;
    let v3 = v2 ^ 32216 ^ y;
    v3
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta40 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta40 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 91.35_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse41(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape42 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square42(f64);

impl Shape42 for Square42 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_43: usize = 84254;
static NAMES_43: [&str; 3] = ["kappa", "beta", "omega"];

#[cfg(test)]
mod tests43 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_43 < 100_000, "limit {} too big", super::LIMIT_43);
    }
}

pub trait Shape44 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square44(f64);

impl Shape44 for Square44 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect45<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma46 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma46 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 89.9_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma47 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma47 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 22.90_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape48 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "theta"
    }
}

struct Square48(f64);

impl Shape48 for Square48 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

fn parse49(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_50: usize = 89231;
static NAMES_50: [&str; 3] = ["gamma", "theta", "beta"];

#[cfg(test)]
mod tests50 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_50 < 100_000, "limit {} too big", super::LIMIT_50);
    }
}

pub trait Shape51 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square51(f64);

impl Shape51 for Square51 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

fn parse52(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

fn parse53(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_54: usize = 55385;
static NAMES_54: [&str; 3] = ["zeta", "theta", "beta"];

#[cfg(test)]
mod tests54 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_54 < 100_000, "limit {} too big", super::LIMIT_54);
    }
}

/// Mixes `x` and `y` for block 55.
pub fn sample55(x: u64, y: u64) -> u64 {
    let v0 = x * 59878 * y;
    let v1 = v0 | 44857 | y;
    let v2 = v1 | 28456 ^ y;
    v2
}

#[derive(Debug, Copy, Clone)]
enum Kind56 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe56(k: Kind56) -> String {
    match k {
        Kind56::Small => String::from("small omega"),
        Kind56::Medium(n) if n > 311 => format!("medium {} over", n),
        Kind56::Medium(n) => format!("medium {}", n),
        Kind56::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa57 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa57 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 85.44_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma58 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma58 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 34.22_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse59(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape60 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square60(f64);

impl Shape60 for Square60 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect61<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind62 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe62(k: Kind62) -> String {
    match k {
        Kind62::Small => String::from("small zeta"),
        Kind62::Medium(n) if n > 516 => format!("medium {} over", n),
        Kind62::Medium(n) => format!("medium {}", n),
        Kind62::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse63(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_64: usize = 34386;
static NAMES_64: [&str; 3] = ["kappa", "sigma", "theta"];

#[cfg(test)]
mod tests64 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_64 < 100_000, "limit {} too big", super::LIMIT_64);
    }
}

fn parse65(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape66 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square66(f64);

impl Shape66 for Square66 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect67<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind68 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe68(k: Kind68) -> String {
    match k {
        Kind68::Small => String::from("small kappa"),
        Kind68::Medium(n) if n > 760 => format!("medium {} over", n),
        Kind68::Medium(n) => format!("medium {}", n),
        Kind68::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind69 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe69(k: Kind69) -> String {
    match k {
        Kind69::Small => String::from("small theta"),
        Kind69::Medium(n) if n > 723 => format!("medium {} over", n),
        Kind69::Medium(n) => format!("medium {}", n),
        Kind69::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect70<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

fn parse71(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 72.
pub fn sample72(x: u64, y: u64) -> u64 {
    let v0 = x - 99514 - y;
    let v1 = v0 ^ 31870 - y;
    let v2 = v1 & 37161 + y;
    let v3 = v2 & 52324 + y;
    v3
}

const LIMIT_73: usize = 96046;
static NAMES_73: [&str; 3] = ["zeta", "lambda", "theta"];

#[cfg(test)]
mod tests73 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_73 < 100_000, "limit {} too big", super::LIMIT_73);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind74 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe74(k: Kind74) -> String {
    match k {
        Kind74::Small => String::from("small beta"),
        Kind74::Medium(n) if n > 657 => format!("medium {} over", n),
        Kind74::Medium(n) => format!("medium {}", n),
        Kind74::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape75 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square75(f64);

impl Shape75 for Square75 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind76 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe76(k: Kind76) -> String {
    match k {
        Kind76::Small => String::from("small theta"),
        Kind76::Medium(n) if n > 874 => format!("medium {} over", n),
        Kind76::Medium(n) => format!("medium {}", n),
        Kind76::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 77.
pub fn sample77(x: u64, y: u64) -> u64 {
    let v0 = x * 16861 * y;
    let v1 = v0 * 58934 & y;
    let v2 = v1 * 23968 + y;
    let v3 = v2 & 43449 & y;
    v3
}

fn parse78(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 79.
pub fn sample79(x: u64, y: u64) -> u64 {
    let v0 = x & 15023 & y;
    let v1 = v0 * 20072 & y;
    let v2 = v1 + 56925 + y;
    let v3 = v2 ^ 2915 & y;
    v3
}

pub trait Shape80 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square80(f64);

impl Shape80 for Square80 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind81 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe81(k: Kind81) -> String {
    match k {
        Kind81::Small => String::from("small delta"),
        Kind81::Medium(n) if n > 364 => format!("medium {} over", n),
        Kind81::Medium(n) => format!("medium {}", n),
        Kind81::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect82<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

pub fn collect83<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 84.
pub fn sample84(x: u64, y: u64) -> u64 {
    let v0 = x | 59310 - y;
    v0
}

const LIMIT_85: usize = 98946;
static NAMES_85: [&str; 3] = ["lambda", "lambda", "theta"];

#[cfg(test)]
mod tests85 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_85 < 100_000, "limit {} too big", super::LIMIT_85);
    }
}

pub trait Shape86 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square86(f64);

impl Shape86 for Square86 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind87 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe87(k: Kind87) -> String {
    match k {
        Kind87::Small => String::from("small delta"),
        Kind87::Medium(n) if n > 477 => format!("medium {} over", n),
        Kind87::Medium(n) => format!("medium {}", n),
        Kind87::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 88.
pub fn sample88(x: u64, y: u64) -> u64 {
    let v0 = x ^ 5416 * y;
    let v1 = v0 + 43542 + y;
    let v2 = v1 | 40574 - y;
    let v3 = v2 ^ 28458 * y;
    v3
}

const LIMIT_89: usize = 77140;
static NAMES_89: [&str; 3] = ["alpha", "lambda", "sigma"];

#[cfg(test)]
mod tests89 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_89 < 100_000, "limit {} too big", super::LIMIT_89);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind90 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe90(k: Kind90) -> String {
    match k {
        Kind90::Small => String::from("small alpha"),
        Kind90::Medium(n) if n > 182 => format!("medium {} over", n),
        Kind90::Medium(n) => format!("medium {}", n),
        Kind90::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind91 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe91(k: Kind91) -> String {
    match k {
        Kind91::Small => String::from("small gamma"),
        Kind91::Medium(n) if n > 688 => format!("medium {} over", n),
        Kind91::Medium(n) => format!("medium {}", n),
        Kind91::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse92(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 93.
pub fn sample93(x: u64, y: u64) -> u64 {
    let v0 = x - 72444 * y;
    let v1 = v0 - 24408 - y;
    v1
}

const LIMIT_94: usize = 90305;
static NAMES_94: [&str; 3] = ["gamma", "zeta", "omega"];

#[cfg(test)]
mod tests94 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_94 < 100_000, "limit {} too big", super::LIMIT_94);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma95 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma95 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 53.91_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

/// Mixes `x` and `y` for block 96.
pub fn sample96(x: u64, y: u64) -> u64 {
    let v0 = x + 7075 ^ y;
    let v1 = v0 * 29783 ^ y;
    let v2 = v1 + 34499 + y;
    v2
}

const LIMIT_97: usize = 69363;
static NAMES_97: [&str; 3] = ["beta", "gamma", "gamma"];

#[cfg(test)]
mod tests97 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_97 < 100_000, "limit {} too big", super::LIMIT_97);
    }
}

fn parse98(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 99.
pub fn sample99(x: u64, y: u64) -> u64 {
    let v0 = x * 24827 | y;
    let v1 = v0 & 48435 + y;
    let v2 = v1 & 27997 - y;
    let v3 = v2 + 61021 & y;
    v3
}

const LIMIT_100: usize = 97471;
static NAMES_100: [&str; 3] = ["alpha", "zeta", "lambda"];

#[cfg(test)]
mod tests100 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_100 < 100_000, "limit {} too big", super::LIMIT_100);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Beta101 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Beta101 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 39.78_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_102: usize = 16018;
static NAMES_102: [&str; 3] = ["gamma", "kappa", "zeta"];

#[cfg(test)]
mod tests102 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_102 < 100_000, "limit {} too big", super::LIMIT_102);
    }
}

pub trait Shape103 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square103(f64);

impl Shape103 for Square103 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub trait Shape104 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square104(f64);

impl Shape104 for Square104 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect105<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

pub fn collect106<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

const LIMIT_107: usize = 16592;
static NAMES_107: [&str; 3] = ["theta", "kappa", "lambda"];

#[cfg(test)]
mod tests107 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_107 < 100_000, "limit {} too big", super::LIMIT_107);
    }
}

pub trait Shape108 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square108(f64);

impl Shape108 for Square108 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind109 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe109(k: Kind109) -> String {
    match k {
        Kind109::Small => String::from("small zeta"),
        Kind109::Medium(n) if n > 15 => format!("medium {} over", n),
        Kind109::Medium(n) => format!("medium {}", n),
        Kind109::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 110.
pub fn sample110(x: u64, y: u64) -> u64 {
    let v0 = x * 14109 ^ y;
    let v1 = v0 & 38338 | y;
    let v2 = v1 + 13130 + y;
    v2
}

#[derive(Debug, Clone, PartialEq)]
pub struct Beta111 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Beta111 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 76.29_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape112 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square112(f64);

impl Shape112 for Square112 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma113 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma113 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 60.78_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse114(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Beta115 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Beta115 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 85.63_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse116(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape117 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square117(f64);

impl Shape117 for Square117 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

fn parse118(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape119 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square119(f64);

impl Shape119 for Square119 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind120 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe120(k: Kind120) -> String {
    match k {
        Kind120::Small => String::from("small lambda"),
        Kind120::Medium(n) if n > 952 => format!("medium {} over", n),
        Kind120::Medium(n) => format!("medium {}", n),
        Kind120::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape121 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square121(f64);

impl Shape121 for Square121 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_122: usize = 79663;
static NAMES_122: [&str; 3] = ["beta", "zeta", "delta"];

#[cfg(test)]
mod tests122 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_122 < 100_000, "limit {} too big", super::LIMIT_122);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind123 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe123(k: Kind123) -> String {
    match k {
        Kind123::Small => String::from("small lambda"),
        Kind123::Medium(n) if n > 462 => format!("medium {} over", n),
        Kind123::Medium(n) => format!("medium {}", n),
        Kind123::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse124(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

fn parse125(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma126 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma126 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 19.12_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind127 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe127(k: Kind127) -> String {
    match k {
        Kind127::Small => String::from("small beta"),
        Kind127::Medium(n) if n > 384 => format!("medium {} over", n),
        Kind127::Medium(n) => format!("medium {}", n),
        Kind127::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape128 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square128(f64);

impl Shape128 for Square128 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind129 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe129(k: Kind129) -> String {
    match k {
        Kind129::Small => String::from("small gamma"),
        Kind129::Medium(n) if n > 381 => format!("medium {} over", n),
        Kind129::Medium(n) => format!("medium {}", n),
        Kind129::Large { width, height } => format!("{}x{}", width, height),
    }
}

const LIMIT_130: usize = 18031;
static NAMES_130: [&str; 3] = ["gamma", "lambda", "alpha"];

#[cfg(test)]
mod tests130 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_130 < 100_000, "limit {} too big", super::LIMIT_130);
    }
}

fn parse131(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind132 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe132(k: Kind132) -> String {
    match k {
        Kind132::Small => String::from("small lambda"),
        Kind132::Medium(n) if n > 234 => format!("medium {} over", n),
        Kind132::Medium(n) => format!("medium {}", n),
        Kind132::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect133<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind134 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe134(k: Kind134) -> String {
    match k {
        Kind134::Small => String::from("small zeta"),
        Kind134::Medium(n) if n > 832 => format!("medium {} over", n),
        Kind134::Medium(n) => format!("medium {}", n),
        Kind134::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape135 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square135(f64);

impl Shape135 for Square135 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect136<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind137 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe137(k: Kind137) -> String {
    match k {
        Kind137::Small => String::from("small beta"),
        Kind137::Medium(n) if n > 128 => format!("medium {} over", n),
        Kind137::Medium(n) => format!("medium {}", n),
        Kind137::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 138.
pub fn sample138(x: u64, y: u64) -> u64 {
    let v0 = x & 87307 & y;
    let v1 = v0 + 44879 + y;
    let v2 = v1 ^ 67647 * y;
    let v3 = v2 + 76211 - y;
    v3
}

const LIMIT_139: usize = 19365;
static NAMES_139: [&str; 3] = ["delta", "kappa", "omega"];

#[cfg(test)]
mod tests139 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_139 < 100_000, "limit {} too big", super::LIMIT_139);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind140 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe140(k: Kind140) -> String {
    match k {
        Kind140::Small => String::from("small theta"),
        Kind140::Medium(n) if n > 928 => format!("medium {} over", n),
        Kind140::Medium(n) => format!("medium {}", n),
        Kind140::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega141 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega141 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 82.66_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_142: usize = 27886;
static NAMES_142: [&str; 3] = ["theta", "sigma", "alpha"];

#[cfg(test)]
mod tests142 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_142 < 100_000, "limit {} too big", super::LIMIT_142);
    }
}

pub fn collect143<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

fn parse144(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect145<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 4)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma146 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma146 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 11.99_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Theta147 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Theta147 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 36.59_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse148(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta149 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta149 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 32.93_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect150<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

pub trait Shape151 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square151(f64);

impl Shape151 for Square151 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 152.
pub fn sample152(x: u64, y: u64) -> u64 {
    let v0 = x & 5702 ^ y;
    v0
}

pub fn collect153<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 154.
pub fn sample154(x: u64, y: u64) -> u64 {
    let v0 = x - 38499 * y;
    let v1 = v0 | 93468 * y;
    v1
}

pub trait Shape155 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square155(f64);

impl Shape155 for Square155 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 156.
pub fn sample156(x: u64, y: u64) -> u64 {
    let v0 = x | 14717 ^ y;
    let v1 = v0 * 19813 & y;
    let v2 = v1 - 9170 + y;
    let v3 = v2 - 28381 - y;
    v3
}

pub trait Shape157 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "theta"
    }
}

struct Square157(f64);

impl Shape157 for Square157 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect158<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

fn parse159(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

fn parse160(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape161 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square161(f64);

impl Shape161 for Square161 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect162<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 5)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 163.
pub fn sample163(x: u64, y: u64) -> u64 {
    let v0 = x + 50761 | y;
    let v1 = v0 * 71994 & y;
    let v2 = v1 * 91527 - y;
    v2
}

#[derive(Debug, Copy, Clone)]
enum Kind164 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe164(k: Kind164) -> String {
    match k {
        Kind164::Small => String::from("small omega"),
        Kind164::Medium(n) if n > 530 => format!("medium {} over", n),
        Kind164::Medium(n) => format!("medium {}", n),
        Kind164::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alpha165 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Alpha165 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 54.69_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma166 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma166 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 44.55_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse167(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_168: usize = 63231;
static NAMES_168: [&str; 3] = ["delta", "beta", "lambda"];

#[cfg(test)]
mod tests168 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_168 < 100_000, "limit {} too big", super::LIMIT_168);
    }
}

pub fn collect169<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

fn parse170(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind171 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe171(k: Kind171) -> String {
    match k {
        Kind171::Small => String::from("small delta"),
        Kind171::Medium(n) if n > 987 => format!("medium {} over", n),
        Kind171::Medium(n) => format!("medium {}", n),
        Kind171::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect172<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 5)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind173 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe173(k: Kind173) -> String {
    match k {
        Kind173::Small => String::from("small theta"),
        Kind173::Medium(n) if n > 938 => format!("medium {} over", n),
        Kind173::Medium(n) => format!("medium {}", n),
        Kind173::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind174 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe174(k: Kind174) -> String {
    match k {
        Kind174::Small => String::from("small zeta"),
        Kind174::Medium(n) if n > 699 => format!("medium {} over", n),
        Kind174::Medium(n) => format!("medium {}", n),
        Kind174::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind175 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe175(k: Kind175) -> String {
    match k {
        Kind175::Small => String::from("small zeta"),
        Kind175::Medium(n) if n > 307 => format!("medium {} over", n),
        Kind175::Medium(n) => format!("medium {}", n),
        Kind175::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse176(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 177.
pub fn sample177(x: u64, y: u64) -> u64 {
    let v0 = x * 97677 * y;
    let v1 = v0 + 42797 - y;
    v1
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta178 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta178 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 68.41_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse179(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_180: usize = 66803;
static NAMES_180: [&str; 3] = ["beta", "lambda", "sigma"];

#[cfg(test)]
mod tests180 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_180 < 100_000, "limit {} too big", super::LIMIT_180);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Theta181 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Theta181 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 32.0_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_182: usize = 32121;
static NAMES_182: [&str; 3] = ["theta", "sigma", "lambda"];

#[cfg(test)]
mod tests182 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_182 < 100_000, "limit {} too big", super::LIMIT_182);
    }
}

pub trait Shape183 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square183(f64);

impl Shape183 for Square183 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect184<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

pub fn collect185<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 4)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 186.
pub fn sample186(x: u64, y: u64) -> u64 {
    let v0 = x + 53970 + y;
    let v1 = v0 * 26893 & y;
    let v2 = v1 & 79026 & y;
    v2
}

#[derive(Debug, Copy, Clone)]
enum Kind187 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe187(k: Kind187) -> String {
    match k {
        Kind187::Small => String::from("small gamma"),
        Kind187::Medium(n) if n > 131 => format!("medium {} over", n),
        Kind187::Medium(n) => format!("medium {}", n),
        Kind187::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega188 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega188 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 93.94_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_189: usize = 53076;
static NAMES_189: [&str; 3] = ["sigma", "sigma", "alpha"];

#[cfg(test)]
mod tests189 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_189 < 100_000, "limit {} too big", super::LIMIT_189);
    }
}

fn parse190(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

fn parse191(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind192 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe192(k: Kind192) -> String {
    match k {
        Kind192::Small => String::from("small kappa"),
        Kind192::Medium(n) if n > 676 => format!("medium {} over", n),
        Kind192::Medium(n) => format!("medium {}", n),
        Kind192::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta193 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta193 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 41.26_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa194 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa194 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 19.14_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind195 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe195(k: Kind195) -> String {
    match k {
        Kind195::Small => String::from("small lambda"),
        Kind195::Medium(n) if n > 59 => format!("medium {} over", n),
        Kind195::Medium(n) => format!("medium {}", n),
        Kind195::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind196 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe196(k: Kind196) -> String {
    match k {
        Kind196::Small => String::from("small kappa"),
        Kind196::Medium(n) if n > 254 => format!("medium {} over", n),
        Kind196::Medium(n) => format!("medium {}", n),
        Kind196::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape197 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square197(f64);

impl Shape197 for Square197 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_198: usize = 28799;
static NAMES_198: [&str; 3] = ["lambda", "kappa", "gamma"];

#[cfg(test)]
mod tests198 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_198 < 100_000, "limit {} too big", super::LIMIT_198);
    }
}

/// Mixes `x` and `y` for block 199.
pub fn sample199(x: u64, y: u64) -> u64 {
    let v0 = x * 39143 | y;
    let v1 = v0 + 21837 & y;
    let v2 = v1 + 49140 * y;
    let v3 = v2 * 18581 ^ y;
    v3
}

#[derive(Debug, Copy, Clone)]
enum Kind200 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe200(k: Kind200) -> String {
    match k {
        Kind200::Small => String::from("small delta"),
        Kind200::Medium(n) if n > 620 => format!("medium {} over", n),
        Kind200::Medium(n) => format!("medium {}", n),
        Kind200::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma201 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma201 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 77.70_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect202<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

fn parse203(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega204 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega204 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 89.93_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect205<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta206 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta206 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 23.4_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa207 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa207 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 98.37_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse208(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind209 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe209(k: Kind209) -> String {
    match k {
        Kind209::Small => String::from("small gamma"),
        Kind209::Medium(n) if n > 785 => format!("medium {} over", n),
        Kind209::Medium(n) => format!("medium {}", n),
        Kind209::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect210<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

fn parse211(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 4th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect212<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

pub trait Shape213 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square213(f64);

impl Shape213 for Square213 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 214.
pub fn sample214(x: u64, y: u64) -> u64 {
    let v0 = x & 26826 ^ y;
    let v1 = v0 ^ 79701 + y;
    v1
}

pub trait Shape215 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square215(f64);

impl Shape215 for Square215 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma216 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma216 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 74.42_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect217<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

fn parse218(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 219.
pub fn sample219(x: u64, y: u64) -> u64 {
    let v0 = x | 8015 - y;
    let v1 = v0 * 46008 | y;
    let v2 = v1 & 50331 ^ y;
    let v3 = v2 + 23079 + y;
    v3
}

pub fn collect220<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 221.
pub fn sample221(x: u64, y: u64) -> u64 {
    let v0 = x ^ 33122 | y;
    let v1 = v0 ^ 53676 | y;
    let v2 = v1 + 90322 ^ y;
    v2
}

pub fn collect222<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 5)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

pub trait Shape223 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square223(f64);

impl Shape223 for Square223 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa224 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa224 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 11.84_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect225<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

fn parse226(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect227<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

const LIMIT_228: usize = 65353;
static NAMES_228: [&str; 3] = ["beta", "zeta", "alpha"];

#[cfg(test)]
mod tests228 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_228 < 100_000, "limit {} too big", super::LIMIT_228);
    }
}

pub fn collect229<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

fn parse230(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega231 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega231 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 74.92_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape232 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "delta"
    }
}

struct Square232(f64);

impl Shape232 for Square232 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect233<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 4 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 234.
pub fn sample234(x: u64, y: u64) -> u64 {
    let v0 = x + 39973 - y;
    let v1 = v0 + 99573 | y;
    v1
}

#[derive(Debug, Copy, Clone)]
enum Kind235 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe235(k: Kind235) -> String {
    match k {
        Kind235::Small => String::from("small sigma"),
        Kind235::Medium(n) if n > 690 => format!("medium {} over", n),
        Kind235::Medium(n) => format!("medium {}", n),
        Kind235::Large { width, height } => format!("{}x{}", width, height),
    }
}

/// Mixes `x` and `y` for block 236.
pub fn sample236(x: u64, y: u64) -> u64 {
    let v0 = x * 54111 * y;
    let v1 = v0 & 41025 + y;
    let v2 = v1 | 90948 & y;
    v2
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta237 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta237 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 92.16_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape238 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square238(f64);

impl Shape238 for Square238 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma239 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma239 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 36.27_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind240 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe240(k: Kind240) -> String {
    match k {
        Kind240::Small => String::from("small theta"),
        Kind240::Medium(n) if n > 952 => format!("medium {} over", n),
        Kind240::Medium(n) => format!("medium {}", n),
        Kind240::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alpha241 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Alpha241 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 28.17_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape242 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square242(f64);

impl Shape242 for Square242 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_243: usize = 49088;
static NAMES_243: [&str; 3] = ["kappa", "kappa", "gamma"];

#[cfg(test)]
mod tests243 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_243 < 100_000, "limit {} too big", super::LIMIT_243);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind244 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe244(k: Kind244) -> String {
    match k {
        Kind244::Small => String::from("small alpha"),
        Kind244::Medium(n) if n > 457 => format!("medium {} over", n),
        Kind244::Medium(n) => format!("medium {}", n),
        Kind244::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect245<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa246 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa246 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 36.11_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape247 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square247(f64);

impl Shape247 for Square247 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub trait Shape248 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square248(f64);

impl Shape248 for Square248 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_249: usize = 32899;
static NAMES_249: [&str; 3] = ["omega", "delta", "zeta"];

#[cfg(test)]
mod tests249 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_249 < 100_000, "limit {} too big", super::LIMIT_249);
    }
}

fn parse250(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta251 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta251 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 68.33_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind252 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe252(k: Kind252) -> String {
    match k {
        Kind252::Small => String::from("small alpha"),
        Kind252::Medium(n) if n > 14 => format!("medium {} over", n),
        Kind252::Medium(n) => format!("medium {}", n),
        Kind252::Large { width, height } => format!("{}x{}", width, height),
    }
}

const LIMIT_253: usize = 28259;
static NAMES_253: [&str; 3] = ["alpha", "theta", "gamma"];

#[cfg(test)]
mod tests253 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_253 < 100_000, "limit {} too big", super::LIMIT_253);
    }
}

/// Mixes `x` and `y` for block 254.
pub fn sample254(x: u64, y: u64) -> u64 {
    let v0 = x - 66075 - y;
    let v1 = v0 * 98218 | y;
    v1
}

#[derive(Debug, Copy, Clone)]
enum Kind255 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe255(k: Kind255) -> String {
    match k {
        Kind255::Small => String::from("small zeta"),
        Kind255::Medium(n) if n > 563 => format!("medium {} over", n),
        Kind255::Medium(n) => format!("medium {}", n),
        Kind255::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect256<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

pub fn collect257<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Theta258 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Theta258 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 59.42_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect259<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

const LIMIT_260: usize = 19707;
static NAMES_260: [&str; 3] = ["theta", "beta", "theta"];

#[cfg(test)]
mod tests260 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_260 < 100_000, "limit {} too big", super::LIMIT_260);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind261 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe261(k: Kind261) -> String {
    match k {
        Kind261::Small => String::from("small gamma"),
        Kind261::Medium(n) if n > 409 => format!("medium {} over", n),
        Kind261::Medium(n) => format!("medium {}", n),
        Kind261::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta262 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta262 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 86.89_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape263 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "theta"
    }
}

struct Square263(f64);

impl Shape263 for Square263 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub trait Shape264 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square264(f64);

impl Shape264 for Square264 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_265: usize = 67102;
static NAMES_265: [&str; 3] = ["zeta", "alpha", "alpha"];

#[cfg(test)]
mod tests265 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_265 < 100_000, "limit {} too big", super::LIMIT_265);
    }
}

/// Mixes `x` and `y` for block 266.
pub fn sample266(x: u64, y: u64) -> u64 {
    let v0 = x ^ 74194 * y;
    let v1 = v0 ^ 48182 * y;
    let v2 = v1 - 22292 ^ y;
    v2
}

#[derive(Debug, Copy, Clone)]
enum Kind267 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe267(k: Kind267) -> String {
    match k {
        Kind267::Small => String::from("small lambda"),
        Kind267::Medium(n) if n > 894 => format!("medium {} over", n),
        Kind267::Medium(n) => format!("medium {}", n),
        Kind267::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind268 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe268(k: Kind268) -> String {
    match k {
        Kind268::Small => String::from("small lambda"),
        Kind268::Medium(n) if n > 645 => format!("medium {} over", n),
        Kind268::Medium(n) => format!("medium {}", n),
        Kind268::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Lambda269 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Lambda269 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 18.45_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_270: usize = 80778;
static NAMES_270: [&str; 3] = ["kappa", "sigma", "zeta"];

#[cfg(test)]
mod tests270 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_270 < 100_000, "limit {} too big", super::LIMIT_270);
    }
}

const LIMIT_271: usize = 7353;
static NAMES_271: [&str; 3] = ["omega", "delta", "kappa"];

#[cfg(test)]
mod tests271 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_271 < 100_000, "limit {} too big", super::LIMIT_271);
    }
}

const LIMIT_272: usize = 74139;
static NAMES_272: [&str; 3] = ["sigma", "zeta", "zeta"];

#[cfg(test)]
mod tests272 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_272 < 100_000, "limit {} too big", super::LIMIT_272);
    }
}

const LIMIT_273: usize = 56668;
static NAMES_273: [&str; 3] = ["sigma", "theta", "gamma"];

#[cfg(test)]
mod tests273 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_273 < 100_000, "limit {} too big", super::LIMIT_273);
    }
}

pub trait Shape274 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square274(f64);

impl Shape274 for Square274 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind275 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe275(k: Kind275) -> String {
    match k {
        Kind275::Small => String::from("small lambda"),
        Kind275::Medium(n) if n > 329 => format!("medium {} over", n),
        Kind275::Medium(n) => format!("medium {}", n),
        Kind275::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect276<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

pub trait Shape277 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square277(f64);

impl Shape277 for Square277 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind278 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe278(k: Kind278) -> String {
    match k {
        Kind278::Small => String::from("small alpha"),
        Kind278::Medium(n) if n > 956 => format!("medium {} over", n),
        Kind278::Medium(n) => format!("medium {}", n),
        Kind278::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape279 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square279(f64);

impl Shape279 for Square279 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect280<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

const LIMIT_281: usize = 81067;
static NAMES_281: [&str; 3] = ["zeta", "zeta", "kappa"];

#[cfg(test)]
mod tests281 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_281 < 100_000, "limit {} too big", super::LIMIT_281);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma282 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma282 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 69.31_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_283: usize = 36238;
static NAMES_283: [&str; 3] = ["zeta", "delta", "sigma"];

#[cfg(test)]
mod tests283 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_283 < 100_000, "limit {} too big", super::LIMIT_283);
    }
}

/// Mixes `x` and `y` for block 284.
pub fn sample284(x: u64, y: u64) -> u64 {
    let v0 = x * 7978 * y;
    let v1 = v0 ^ 62130 & y;
    let v2 = v1 | 46735 * y;
    v2
}

pub trait Shape285 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square285(f64);

impl Shape285 for Square285 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

fn parse286(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

/// Mixes `x` and `y` for block 287.
pub fn sample287(x: u64, y: u64) -> u64 {
    let v0 = x ^ 80777 | y;
    v0
}

pub fn collect288<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

const LIMIT_289: usize = 32704;
static NAMES_289: [&str; 3] = ["kappa", "sigma", "alpha"];

#[cfg(test)]
mod tests289 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_289 < 100_000, "limit {} too big", super::LIMIT_289);
    }
}

/// Mixes `x` and `y` for block 290.
pub fn sample290(x: u64, y: u64) -> u64 {
    let v0 = x ^ 96851 - y;
    v0
}

fn parse291(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 2 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

fn parse292(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect293<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

pub fn collect294<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 295.
pub fn sample295(x: u64, y: u64) -> u64 {
    let v0 = x & 84602 | y;
    v0
}

pub trait Shape296 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "delta"
    }
}

struct Square296(f64);

impl Shape296 for Square296 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_297: usize = 77724;
static NAMES_297: [&str; 3] = ["beta", "kappa", "theta"];

#[cfg(test)]
mod tests297 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_297 < 100_000, "limit {} too big", super::LIMIT_297);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Lambda298 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Lambda298 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 6.22_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse299(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 3 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma300 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma300 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 86.70_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

/// Mixes `x` and `y` for block 301.
pub fn sample301(x: u64, y: u64) -> u64 {
    let v0 = x ^ 36370 + y;
    v0
}

pub trait Shape302 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square302(f64);

impl Shape302 for Square302 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 303.
pub fn sample303(x: u64, y: u64) -> u64 {
    let v0 = x * 29694 * y;
    let v1 = v0 + 77177 | y;
    let v2 = v1 * 16650 | y;
    let v3 = v2 ^ 5809 * y;
    v3
}

const LIMIT_304: usize = 99710;
static NAMES_304: [&str; 3] = ["alpha", "beta", "gamma"];

#[cfg(test)]
mod tests304 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_304 < 100_000, "limit {} too big", super::LIMIT_304);
    }
}

fn parse305(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind306 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe306(k: Kind306) -> String {
    match k {
        Kind306::Small => String::from("small alpha"),
        Kind306::Medium(n) if n > 685 => format!("medium {} over", n),
        Kind306::Medium(n) => format!("medium {}", n),
        Kind306::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape307 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square307(f64);

impl Shape307 for Square307 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect308<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

/// Mixes `x` and `y` for block 309.
pub fn sample309(x: u64, y: u64) -> u64 {
    let v0 = x + 88476 - y;
    let v1 = v0 | 25805 | y;
    v1
}

pub fn collect310<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 4)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

pub fn collect311<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

pub trait Shape312 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "beta"
    }
}

struct Square312(f64);

impl Shape312 for Square312 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind313 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe313(k: Kind313) -> String {
    match k {
        Kind313::Small => String::from("small theta"),
        Kind313::Medium(n) if n > 572 => format!("medium {} over", n),
        Kind313::Medium(n) => format!("medium {}", n),
        Kind313::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect314<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 5)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

pub trait Shape315 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square315(f64);

impl Shape315 for Square315 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega316 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega316 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 8.65_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape317 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square317(f64);

impl Shape317 for Square317 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_318: usize = 24649;
static NAMES_318: [&str; 3] = ["delta", "theta", "delta"];

#[cfg(test)]
mod tests318 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_318 < 100_000, "limit {} too big", super::LIMIT_318);
    }
}

const LIMIT_319: usize = 21484;
static NAMES_319: [&str; 3] = ["omega", "zeta", "gamma"];

#[cfg(test)]
mod tests319 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_319 < 100_000, "limit {} too big", super::LIMIT_319);
    }
}

pub trait Shape320 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square320(f64);

impl Shape320 for Square320 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind321 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe321(k: Kind321) -> String {
    match k {
        Kind321::Small => String::from("small theta"),
        Kind321::Medium(n) if n > 808 => format!("medium {} over", n),
        Kind321::Medium(n) => format!("medium {}", n),
        Kind321::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub fn collect322<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 4)
        .filter(|&n| n % 2 == 0)
        .take(limit)
        .collect()
}

pub trait Shape323 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "sigma"
    }
}

struct Square323(f64);

impl Shape323 for Square323 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect324<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

fn parse325(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape326 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "theta"
    }
}

struct Square326(f64);

impl Shape326 for Square326 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect327<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

fn parse328(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape329 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square329(f64);

impl Shape329 for Square329 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub trait Shape330 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "theta"
    }
}

struct Square330(f64);

impl Shape330 for Square330 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa331 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa331 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 91.59_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub fn collect332<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 4)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind333 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe333(k: Kind333) -> String {
    match k {
        Kind333::Small => String::from("small kappa"),
        Kind333::Medium(n) if n > 869 => format!("medium {} over", n),
        Kind333::Medium(n) => format!("medium {}", n),
        Kind333::Large { width, height } => format!("{}x{}", width, height),
    }
}

const LIMIT_334: usize = 99327;
static NAMES_334: [&str; 3] = ["zeta", "theta", "lambda"];

#[cfg(test)]
mod tests334 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_334 < 100_000, "limit {} too big", super::LIMIT_334);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma335 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma335 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 19.62_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_336: usize = 7526;
static NAMES_336: [&str; 3] = ["theta", "beta", "alpha"];

#[cfg(test)]
mod tests336 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_336 < 100_000, "limit {} too big", super::LIMIT_336);
    }
}

pub fn collect337<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma338 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma338 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 40.26_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

/// Mixes `x` and `y` for block 339.
pub fn sample339(x: u64, y: u64) -> u64 {
    let v0 = x | 93038 - y;
    let v1 = v0 ^ 85851 - y;
    let v2 = v1 | 43448 - y;
    v2
}

#[derive(Debug, Copy, Clone)]
enum Kind340 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe340(k: Kind340) -> String {
    match k {
        Kind340::Small => String::from("small sigma"),
        Kind340::Medium(n) if n > 572 => format!("medium {} over", n),
        Kind340::Medium(n) => format!("medium {}", n),
        Kind340::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta341 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta341 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 82.64_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_342: usize = 56020;
static NAMES_342: [&str; 3] = ["kappa", "sigma", "alpha"];

#[cfg(test)]
mod tests342 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_342 < 100_000, "limit {} too big", super::LIMIT_342);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind343 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe343(k: Kind343) -> String {
    match k {
        Kind343::Small => String::from("small zeta"),
        Kind343::Medium(n) if n > 154 => format!("medium {} over", n),
        Kind343::Medium(n) => format!("medium {}", n),
        Kind343::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape344 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "alpha"
    }
}

struct Square344(f64);

impl Shape344 for Square344 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

fn parse345(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect346<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 6)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Zeta347 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Zeta347 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 45.36_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

fn parse348(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 3th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub fn collect349<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 2)
        .filter(|&n| n % 8 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Copy, Clone)]
enum Kind350 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe350(k: Kind350) -> String {
    match k {
        Kind350::Small => String::from("small alpha"),
        Kind350::Medium(n) if n > 550 => format!("medium {} over", n),
        Kind350::Medium(n) => format!("medium {}", n),
        Kind350::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse351(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 5th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Copy, Clone)]
enum Kind352 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe352(k: Kind352) -> String {
    match k {
        Kind352::Small => String::from("small lambda"),
        Kind352::Medium(n) if n > 392 => format!("medium {} over", n),
        Kind352::Medium(n) => format!("medium {}", n),
        Kind352::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse353(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_354: usize = 60873;
static NAMES_354: [&str; 3] = ["kappa", "delta", "lambda"];

#[cfg(test)]
mod tests354 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_354 < 100_000, "limit {} too big", super::LIMIT_354);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta355 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta355 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 66.51_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape356 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "delta"
    }
}

struct Square356(f64);

impl Shape356 for Square356 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 357.
pub fn sample357(x: u64, y: u64) -> u64 {
    let v0 = x - 25818 | y;
    let v1 = v0 ^ 10743 | y;
    v1
}

/// Mixes `x` and `y` for block 358.
pub fn sample358(x: u64, y: u64) -> u64 {
    let v0 = x | 79592 ^ y;
    let v1 = v0 ^ 39217 + y;
    v1
}

pub trait Shape359 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square359(f64);

impl Shape359 for Square359 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind360 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe360(k: Kind360) -> String {
    match k {
        Kind360::Small => String::from("small omega"),
        Kind360::Medium(n) if n > 540 => format!("medium {} over", n),
        Kind360::Medium(n) => format!("medium {}", n),
        Kind360::Large { width, height } => format!("{}x{}", width, height),
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind361 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe361(k: Kind361) -> String {
    match k {
        Kind361::Small => String::from("small zeta"),
        Kind361::Medium(n) if n > 294 => format!("medium {} over", n),
        Kind361::Medium(n) => format!("medium {}", n),
        Kind361::Large { width, height } => format!("{}x{}", width, height),
    }
}

fn parse362(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 4 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

const LIMIT_363: usize = 86503;
static NAMES_363: [&str; 3] = ["omega", "theta", "kappa"];

#[cfg(test)]
mod tests363 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_363 < 100_000, "limit {} too big", super::LIMIT_363);
    }
}

pub fn collect364<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 7)
        .filter(|&n| n % 5 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma365 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma365 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 92.6_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alpha366 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Alpha366 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 17.17_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sigma367 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Sigma367 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 68.93_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Beta368 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Beta368 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 55.24_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alpha369 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Alpha369 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 53.30_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta370 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta370 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 87.98_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_371: usize = 67813;
static NAMES_371: [&str; 3] = ["omega", "sigma", "theta"];

#[cfg(test)]
mod tests371 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_371 < 100_000, "limit {} too big", super::LIMIT_371);
    }
}

fn parse372(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 2th entry */
        if n % 5 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

pub trait Shape373 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "kappa"
    }
}

struct Square373(f64);

impl Shape373 for Square373 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind374 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe374(k: Kind374) -> String {
    match k {
        Kind374::Small => String::from("small zeta"),
        Kind374::Medium(n) if n > 305 => format!("medium {} over", n),
        Kind374::Medium(n) => format!("medium {}", n),
        Kind374::Large { width, height } => format!("{}x{}", width, height),
    }
}

const LIMIT_375: usize = 35245;
static NAMES_375: [&str; 3] = ["zeta", "delta", "delta"];

#[cfg(test)]
mod tests375 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_375 < 100_000, "limit {} too big", super::LIMIT_375);
    }
}

/// Mixes `x` and `y` for block 376.
pub fn sample376(x: u64, y: u64) -> u64 {
    let v0 = x - 18998 - y;
    let v1 = v0 * 88632 & y;
    let v2 = v1 ^ 99704 * y;
    let v3 = v2 & 52302 | y;
    v3
}

pub fn collect377<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 1)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa378 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa378 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 89.45_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

/// Mixes `x` and `y` for block 379.
pub fn sample379(x: u64, y: u64) -> u64 {
    let v0 = x + 97505 - y;
    v0
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kappa380 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Kappa380 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 92.77_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

/// Mixes `x` and `y` for block 381.
pub fn sample381(x: u64, y: u64) -> u64 {
    let v0 = x - 16843 & y;
    let v1 = v0 - 70558 - y;
    let v2 = v1 ^ 97763 & y;
    v2
}

fn parse382(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
    let mut out = Vec::new();
    for (n, part) in input.split(',').enumerate() {
        /* skip every 6th entry */
        if n % 6 == 1 {
            continue;
        }
        out.push(part.trim().parse::<i32>()?);
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Theta383 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Theta383 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 74.24_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

const LIMIT_384: usize = 14011;
static NAMES_384: [&str; 3] = ["gamma", "theta", "zeta"];

#[cfg(test)]
mod tests384 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_384 < 100_000, "limit {} too big", super::LIMIT_384);
    }
}

#[derive(Debug, Copy, Clone)]
enum Kind385 {
    Small,
    Medium(u32),
    Large { width: u32, height: u32 },
}

fn describe385(k: Kind385) -> String {
    match k {
        Kind385::Small => String::from("small delta"),
        Kind385::Medium(n) if n > 400 => format!("medium {} over", n),
        Kind385::Medium(n) => format!("medium {}", n),
        Kind385::Large { width, height } => format!("{}x{}", width, height),
    }
}

pub trait Shape386 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "gamma"
    }
}

struct Square386(f64);

impl Shape386 for Square386 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub trait Shape387 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square387(f64);

impl Shape387 for Square387 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect388<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 3)
        .filter(|&n| n % 7 == 0)
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Gamma389 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Gamma389 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 27.52_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

// padding 4993
// padding 4994
// padding 4995
// padding 4996
// padding 4997
// padding 4998
// padding 4999
