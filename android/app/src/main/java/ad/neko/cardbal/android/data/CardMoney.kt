package ad.neko.cardbal.android.data

import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import kotlin.math.abs

fun formatTransactionAmount(transaction: TransitTransaction, locale: Locale = Locale.getDefault()): String {
    val credit = if (transaction.amountIsSigned) transaction.amount > 0
        else transaction.category == TransactionCategory.topUp || transaction.category == TransactionCategory.refund
    val sign = if (credit) "+" else "-"
    return sign + formatCardMoney(abs(transaction.amount), transaction.currencyCode, transaction.fractionDigits, locale)
}

/** Convert integer on-card units at presentation without losing cents to a Double. */
fun formatCardMoney(amount: Long, currencyCode: String?, fractionDigits: Int, locale: Locale = Locale.getDefault()): String {
    require(fractionDigits in 0..3)
    val code = currencyCode ?: "JPY"
    val symbol = when (code) {
        "NZD" -> "NZ$"
        "IDR" -> "Rp"
        else -> Currency.getInstance(code).getSymbol(locale)
    }
    val formatter = NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = fractionDigits
        maximumFractionDigits = fractionDigits
    }
    return symbol + formatter.format(BigDecimal.valueOf(amount, fractionDigits))
}
