// Deterministic benchmark corpus (seed 1); not meant to compile.
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct Omega0 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega0 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 96.70_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Omega1 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega1 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 30.2_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape2 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "zeta"
    }
}

struct Square2(f64);

impl Shape2 for Square2 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Delta3 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Delta3 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 52.0_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape4 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square4(f64);

impl Shape4 for Square4 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub fn collect5<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 8)
        .filter(|&n| n % 3 == 0)
        .take(limit)
        .collect()
}

pub fn collect6<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {
    items
        .iter()
        .map(|item| item.clone().into() * 9)
        .filter(|&n| n % 6 == 0)
        .take(limit)
        .collect()
}

const LIMIT_7: usize = 56004;
static NAMES_7: [&str; 3] = ["zeta", "gamma", "beta"];

#[cfg(test)]
mod tests7 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_7 < 100_000, "limit {} too big", super::LIMIT_7);
    }
}

/// Mixes `x` and `y` for block 8.
pub fn sample8(x: u64, y: u64) -> u64 {
    let v0 = x + 13925 * y;
    let v1 = v0 + 3786 | y;
    let v2 = v1 | 18589 & y;
    v2
}

fn parse9(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {
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

#[derive(Debug, Clone, PartialEq)]
pub struct Omega10 {
    pub name: String,
    pub count: usize,
    weight: f64,
}

impl Omega10 {
    pub fn new(name: &str, count: usize) -> Self {
        Self { name: name.to_string(), count, weight: 1.63_f64 }
    }

    pub fn score(&self) -> f64 {
        self.weight * self.count as f64 // scaled by count
    }
}

pub trait Shape11 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "omega"
    }
}

struct Square11(f64);

impl Shape11 for Square11 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

const LIMIT_12: usize = 73794;
static NAMES_12: [&str; 3] = ["omega", "beta", "alpha"];

#[cfg(test)]
mod tests12 {
    #[test]
    fn limit_is_sane() {
        assert!(super::LIMIT_12 < 100_000, "limit {} too big", super::LIMIT_12);
    }
}

pub trait Shape13 {
    fn area(&self) -> f64;
    fn label(&self) -> &'static str {
        "lambda"
    }
}

struct Square13(f64);

impl Shape13 for Square13 {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// Mixes `x` and `y` for block 14.
pub fn sample14(x: u64, y: u64) -> u64 {
    let v0 = x + 72748 & y;
    let v1 = v0 - 1055 - y;
    v1
}

// padding 198
// padding 199
