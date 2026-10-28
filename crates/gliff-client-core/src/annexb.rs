//! H.264 Annex B inspection for the encoded payloads the server sends.
//!
//! The server never fills `StreamConfig::extradata`: parameter sets ride
//! in-band, ahead of each IDR, as Annex B start-code-delimited NAL units.
//! This module only reads NAL headers; it does not parse slice syntax.

/// NAL unit types used by the contract checks (ITU-T H.264 table 7-1).
pub mod nal {
    pub const NON_IDR_SLICE: u8 = 1;
    pub const IDR_SLICE: u8 = 5;
    pub const SEI: u8 = 6;
    pub const SPS: u8 = 7;
    pub const PPS: u8 = 8;
    pub const ACCESS_UNIT_DELIMITER: u8 = 9;
}

/// One NAL unit found in an Annex B byte stream, without its start code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NalUnit<'a> {
    pub nal_type: u8,
    pub bytes: &'a [u8],
}

/// Split an Annex B stream at its 3- or 4-byte start codes. Bytes before the
/// first start code are not a NAL unit and make the stream invalid.
pub fn nal_units(stream: &[u8]) -> Result<Vec<NalUnit<'_>>, AnnexBError> {
    let starts = start_codes(stream);
    match starts.first() {
        None => return Err(AnnexBError::NoStartCode),
        Some(&(at, _)) if at != 0 => return Err(AnnexBError::LeadingBytes(at)),
        Some(_) => {}
    }
    let mut units = Vec::with_capacity(starts.len());
    for (i, &(at, len)) in starts.iter().enumerate() {
        let begin = at + len;
        let end = starts.get(i + 1).map_or(stream.len(), |&(next, _)| next);
        let bytes = &stream[begin..end];
        let Some(&header) = bytes.first() else {
            return Err(AnnexBError::EmptyUnit(begin));
        };
        if header & 0x80 != 0 {
            return Err(AnnexBError::ForbiddenBit(begin));
        }
        units.push(NalUnit {
            nal_type: header & 0x1f,
            bytes,
        });
    }
    Ok(units)
}

/// The NAL unit types of a stream, in order.
pub fn nal_types(stream: &[u8]) -> Result<Vec<u8>, AnnexBError> {
    Ok(nal_units(stream)?.iter().map(|u| u.nal_type).collect())
}

/// Whether the access unit can start decoding on its own: it carries an SPS
/// and a PPS before its first IDR slice.
pub fn is_self_contained_idr(stream: &[u8]) -> Result<bool, AnnexBError> {
    let types = nal_types(stream)?;
    let Some(idr) = types.iter().position(|&t| t == nal::IDR_SLICE) else {
        return Ok(false);
    };
    let before = &types[..idr];
    Ok(before.contains(&nal::SPS) && before.contains(&nal::PPS))
}

/// Positions and lengths of every start code. A zero byte ahead of a 3-byte
/// start code makes it a 4-byte one.
fn start_codes(stream: &[u8]) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1 {
            if i > 0 && stream[i - 1] == 0 {
                found.push((i - 1, 4));
            } else {
                found.push((i, 3));
            }
            i += 3;
        } else {
            i += 1;
        }
    }
    found
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AnnexBError {
    #[error("no Annex B start code")]
    NoStartCode,
    #[error("{0} bytes precede the first start code")]
    LeadingBytes(usize),
    #[error("empty NAL unit at byte {0}")]
    EmptyUnit(usize),
    #[error("NAL unit at byte {0} sets the forbidden zero bit")]
    ForbiddenBit(usize),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_three_and_four_byte_start_codes() {
        let stream = [
            0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4,
        ];
        assert_eq!(nal_types(&stream).unwrap(), vec![7, 8, 5]);
        assert!(is_self_contained_idr(&stream).unwrap());
    }

    #[test]
    fn rejects_streams_that_are_not_annex_b() {
        assert_eq!(nal_types(&[1, 2, 3]), Err(AnnexBError::NoStartCode));
        assert_eq!(
            nal_types(&[9, 0, 0, 1, 0x65]),
            Err(AnnexBError::LeadingBytes(1))
        );
        assert_eq!(
            nal_types(&[0, 0, 1, 0x80]),
            Err(AnnexBError::ForbiddenBit(3))
        );
    }

    #[test]
    fn an_idr_without_parameter_sets_is_not_self_contained() {
        assert!(!is_self_contained_idr(&[0, 0, 1, 0x65, 1]).unwrap());
        assert!(!is_self_contained_idr(&[0, 0, 1, 0x67, 0, 0, 1, 0x41]).unwrap());
    }
}
