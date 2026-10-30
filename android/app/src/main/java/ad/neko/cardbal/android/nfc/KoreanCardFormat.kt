package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/** Same KS X 6924 record layouts and conservative timestamp choices as the iOS reader. */
internal object KoreanCardFormat {
    data class Purse(val serial: String, val issuer: Int, val cardType: Int, val issueDate: String?, val expiryDate: String?) {
        val isUMoney get() = issuer == 1 && serial.replace(" ", "").startsWith("16")
        val isClimate get() = !isUMoney && (cardType and 0xb0) == 0xb0
    }
    fun tlv(data: ByteArray, tag: Int): ByteArray? {
        val matches = mutableListOf<ByteArray>()
        fun parse(start: Int, end: Int, depth: Int): Boolean {
            if (depth > 8) return false
            var p = start
            while (p < end) {
                val first = data[p++].toInt() and 255
                var current = first
                if (first and 31 == 31) {
                    var count = 0
                    do {
                        if (p >= end || ++count > 3) return false
                        val next = data[p++].toInt() and 255
                        current = (current shl 8) or next
                    } while (next and 128 != 0)
                }
                if (p >= end) return false
                var length = data[p++].toInt() and 255
                if (length and 128 != 0) {
                    val count = length and 127
                    if (count !in 1..3 || p + count > end) return false
                    length = 0
                    repeat(count) { length = (length shl 8) or (data[p++].toInt() and 255) }
                }
                if (length > end - p) return false
                if (current == tag) matches.add(data.copyOfRange(p, p + length))
                else if (first and 32 != 0 && !parse(p, p + length, depth + 1)) return false
                p += length
            }
            return true
        }
        return if (parse(0, data.size, 0)) matches.singleOrNull() else null
    }
    fun purse(fci: ByteArray): Purse? {
        val p = tlv(fci, 0xb0)?.takeIf { it.size >= 47 } ?: return null
        val serial = p.copyOfRange(4, 12).takeIf { a -> a.any { it != 0.toByte() } && a.any { it != 0xff.toByte() } }?.hexString()?.chunked(4)?.joinToString(" ") ?: return null
        fun day(offset: Int): String? = bcdDate(p.copyOfRange(offset, offset + 4))?.let { "%04d-%02d-%02d".format(it[0], it[1], it[2]) }
        return Purse(serial, p[3].toInt() and 255, p[0].toInt() and 255, day(17), day(21))
    }
    private fun bcdDate(bytes: ByteArray): List<Int>? {
        val v = bytes.map { val b = it.toInt() and 255; if (b shr 4 > 9 || b and 15 > 9) return null; (b shr 4) * 10 + (b and 15) }
        if (v.size < 4) return null
        val parts = listOf(v[0] * 100 + v[1], v[2], v[3]) + v.drop(4)
        if (parts[0] !in 2000..2199) return null
        if (runCatching { java.time.LocalDate.of(parts[0],parts[1],parts[2]) }.isFailure) return null
        return parts
    }
    fun bcdTimestamp(bytes: ByteArray, zone: String): Instant? {
        val p = bcdDate(bytes)?.takeIf { it.size == 6 } ?: return null
        return local(p[0], p[1], p[2], p[3], p[4], p[5], zone)
    }
    private fun local(y: Int, m: Int, d: Int, h: Int, minute: Int, second: Int, zone: String): Instant? = runCatching {
        val time = LocalDateTime.of(y, m, d, h, minute, second)
        val issuer = ZoneId.of(zone)
        val offset = issuer.rules.getValidOffsets(time).singleOrNull() ?: return null
        Instant.fromEpochMilliseconds(time.toInstant(offset).toEpochMilli())
    }.getOrNull()
    private enum class Layout { Standard, Regional, Mybi, Total, Gwangju }
    private fun layout(code: Int): Layout = when {
        code == 870 || code in setOf(877,905,909) || code in 600..619 || code in 632..636 || code in 641..660 || code in 711..713 || code in 776..799 || code in setOf(887,936,940) || code in 901..904 || code in 913..916 || code in 925..927 -> Layout.Mybi
        code in 621..631 || code in 637..640 || code in 684..685 || code in setOf(729,888) || code in 928..931 -> Layout.Total
        code == 691 || code in 770..775 || code == 871 -> Layout.Gwangju
        code in 672..683 || code in 828..830 || code in 701..703 || code in 752..755 || code in 759..762 || code in 824..825 || code in 810..820 || code in 990..999 || code == 853 -> Layout.Regional
        else -> Layout.Standard
    }
    fun transitTimestamp(data: ByteArray, zone: String, reference: Instant): Instant? {
        if (data.size != 52) return null
        val mode = JapaneseCardFormats.uint(data,9,2).toInt()
        val format = layout(mode)
        if (format != Layout.Mybi) {
            bcdTimestamp(data.copyOfRange(11,18),zone)?.let { return it }
            if (format == Layout.Total || format == Layout.Gwangju && mode != 770) return null
        }
        if (format == Layout.Mybi || format == Layout.Gwangju) {
            val offset = if ((data[2].toInt() and 1) == 0) 11 else 14
            val packed = JapaneseCardFormats.uint(data,offset,3).toInt()
            if (packed == 0 || packed == 0xfbf000) return null
            val refYear = java.time.Instant.ofEpochMilli(reference.toEpochMilliseconds()).atZone(ZoneId.of(zone)).year
            for (year in refYear downTo maxOf(2000,refYear-47)) {
                if (year and 15 != packed shr 20 and 15) continue
                val date = local(year,packed shr 16 and 15,packed shr 11 and 31,packed shr 6 and 31,packed and 63,0,zone) ?: return null
                if (date <= reference) return date
            }
            return null
        }
        val day = JapaneseCardFormats.uint(data,11,2).toInt()
        val time = JapaneseCardFormats.uint(data,13,2).toInt()
        return local(2000+(day shr 9),day shr 5 and 15,day and 31,time shr 11,time shr 5 and 63,((time and 31) shl 1) or ((data[15].toInt() and 255) shr 7),zone)
    }
    fun decode(data: ByteArray, raw: String, family: String, index: Int, reference: Instant, modeClass: String? = null, station: String? = null, isTransit: Boolean = false): TransitTransaction? {
        if (data.isEmpty() || data.all { it == 0.toByte() } || data.all { it == 0xff.toByte() }) return null
        if(isTransit && data.size>52) return decode(data.copyOfRange(0,52),raw,family,index,reference,modeClass,station,true)
        val umoney = family.equals("U-Money",true)
        val currency = if (umoney) "MNT" else "KRW"
        val zone = if (umoney) "Asia/Ulaanbaatar" else "Asia/Seoul"
        val uint = JapaneseCardFormats::uint
        if (data.size == 52) {
            val mode = uint(data,9,2,false).toInt(); val format = layout(mode)
            val offsets = if (format in setOf(Layout.Mybi,Layout.Total,Layout.Gwangju)) listOf(40,36,22) else listOf(22,40,36)
            val selectedFare = offsets.map { uint(data,it,2,false) }.firstOrNull { it in 100..10000 }
            val fare = selectedFare ?: 0
            val event = data[2].toInt() and 255
            val locationCode = data.copyOfRange(5,11).hexString()
            val name = station ?: "Station ${data.copyOfRange(5,9).hexString()}"
            val category = when {
                event !in 0..1 -> TransactionCategory.unknown
                modeClass == "R" -> if (event == 0) TransactionCategory.trainOn else TransactionCategory.trainOff
                modeClass == "B" || umoney -> if (event == 0) TransactionCategory.busOn else TransactionCategory.busOff
                else -> TransactionCategory.unknown
            }
            return TransitTransaction(date=transitTimestamp(data,zone,reference),amount=-fare,terminalID=locationCode,recordNumber=index+1,
                type=if(event==0) "Tap-on" else if(event==1) "Tap-off" else "Transit event %02X".format(event),category=category,
                location=name,entryStation=if(event==0) name else null,exitStation=if(event==1) name else null,
                entryStationCode=if(event==0) locationCode else null,exitStationCode=if(event==1) locationCode else null,
                rawData=raw,currencyCode=currency,issuerTimeZone=zone,amountIsSigned=true,amountKnown=selectedFare!=null)
        }
        if(isTransit && data.size in 18..51) {
            return TransitTransaction(date=bcdTimestamp(data.copyOfRange(2,9),zone),amount=-uint(data,10,4,false),balanceAfter=uint(data,14,4,false),
                type="Transit",rawData=raw,currencyCode=currency,issuerTimeZone=zone,amountIsSigned=true)
        }
        if (data.size < 14) return null
        val amount=uint(data,10,4,false); val credit=data[0]==2.toByte(); val counter=uint(data,6,4,false)
        val date=if(data.size>=33 && !family.equals("NAMANE",true)) bcdTimestamp(data.copyOfRange(26,33),zone) else null
        return TransitTransaction(date=date,amount=if(credit) amount else -amount,balanceAfter=uint(data,2,4,false),
            terminalID=if(data.size>=22) data.copyOfRange(14,22).hexString() else null,
            recordNumber=counter.takeIf{it<=Int.MAX_VALUE}?.toInt(),recordCounter=counter,
            type=if(credit) "Top-up" else if(amount==0L) "Entry" else "Payment",
            category=if(credit) TransactionCategory.topUp else if(amount==0L) TransactionCategory.tapOn else TransactionCategory.payment,
            rawData=raw,currencyCode=currency,issuerTimeZone=zone,amountIsSigned=true)
    }
}
