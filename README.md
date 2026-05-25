# Contract Achitecture
------
```bash
TaxToken.sol
│
├── Inheritance
│   ├── ERC20Pausable    → standard token + pause
│   └── Ownable          → access control
│
├── Constants
│   └── MAX_TOTAL_TAX_BPS = 2500 (25%)
│
├── State Variables
│   ├── uint256 treasuryTaxBps    (default: 300 = 3%)
│   ├── uint256 burnTaxBps        (default: 200 = 2%)
│   ├── address treasuryWallet
│   ├── uint256 totalTaxCollected
│   ├── uint256 totalBurned
│   └── mapping _isExemptFromTax
│
├── Events
│   ├── TaxApplied
│   ├── TreasuryTaxUpdated
│   ├── BurnTaxUpdated
│   ├── TreasuryWalletUpdated
│   └── ExemptionUpdated
│
├── Errors
│   ├── TaxTooHigh
│   ├── InvalidTreasuryWallet
│   ├── InvalidAddress
│   └── NoChangeDetected
│
├── Constructor
│   ├── ERC20("Tax Example Token", "TAX")
│   ├── Ownable(msg.sender)
│   ├── Set treasuryWallet
│   ├── Set initial tax rates
│   ├── Set exemptions (this, owner, treasury)
│   └── Mint initial supply ke deployer
│
├── Core Override
│   └── _update()        ← jantung contract ini
│       ├── Check paused (dari ERC20Pausable)
│       ├── Check exemption
│       ├── Calculate tax
│       ├── Transfer ke penerima
│       ├── Transfer treasury tax
│       ├── Burn tax
│       └── Update statistics + emit event
│
├── Admin Functions (onlyOwner)
│   ├── setTreasuryTax()
│   ├── setBurnTax()
│   ├── setTreasuryWallet()
│   ├── setExemption()
│   ├── pause()
│   ├── unpause()
│   └── mint()
│
└── View Functions
    ├── isExemptFromTax()
    ├── getTaxInfo()
    └── calculateTax()
```
----

## 1. Prameter Token
### Identitas Token
```bash
Nama            : Tax Example Token
Symbol          : TAX
Decimals        : 18 (standar)
Total Supply    : 1,000,000,000 (1 MIliar)
                  -> sengaja supply besar karena tax mecanism membuat
                     token terus berkuranng (burn). 
```

### Tax Configuration
```bash
Treasury Tax   : 3% -> masuk ke treasury wallet
Burn Tax       : 2% -> token dihancurkan
Total Tax      : 5% -> yang dipotong dari setiap transfer

Maximum Tax    : 25% total (hard cap, tidak bisa diubah)
                 -> proteksi user dari rugpull
                 -> 25% dibagi antara semua jenis tax

kenapa 5% total untuk contoh ini?
-> cukup terasa efeknya untuk testing
-> tidak terlalu tinggi sehingga transaksi gagal DEX
-> realisitis untuk production token
```

### Treasury Configuration
```bash
Treasury address  : ditentukan saat deploy kontrak (constructor parameter)
                    -> bisa wallet owner, multisig, atau contract lain
                    -> bisa diupdate oleh owner setelah deploy

kenapa treasury bisa diupdate?
-> project mungkin pindak ke mulitisig dikemudian hari
-> kontrol yang fleksibel untuk project yang berkembang
```
----

## 2. Exampt Address List
tidak semua transfer boleh kena tax. kita perlu daftar address yang dikecualikan dari tax mecanism.

siapa yang exampt?
```bash
1. address(this) - contract itu sendiri
   kenapa: saat kontrak mendistribusikan token untuk liquidity atau treasury,
   tidak boleh kena tax dari dirinya sendiri - infiniti loop.

2. owner - deployer kontrak
   kenapa: setup awal seperti menambah liquidity tidak boleh kena tax.
   ini juga memudahkan testing dan maintenance

3. treasury - wallet penerima tax
   kenapa: saat treasury mengirim token (misalnya untuk bayar tim),
   tidak boleh kena tax lagi - double taxation.

4. DEX pair address (ditambahkan manual setelah deploy)
   kenapa: ini adlaah address uniswap/pancakeswap pool.
   kalau pool kena tax saat swab, kalkulasi AMM (Automated Market Maker) jadi salah.
   pair address harus diketahui setelah listing.
```

### Struktur example list:
```bash
// mapping: address -> apakah exampt dari tax?
mapping(address => bool) private isExamptFromTax;

// siapa yang bisa tambah/hapus exampt?
// -> hanya owner (onlyOwner modifier)

// apakah exampt bisa dilihat publik?
// -> ya, via getter function
// -> transparansi penting untuk trust
```
----

## 3. State Variabel Lengkap
ini adalah semua data yang perlu disimpan di blockchain
```bash
IDENTITAS TOKEN:
--------------------------------------------------------------------------------------
(dihandle OPenZeppelin ERC20 - nama, symbol, decimals)

TAX CONFIGURATION:
--------------------------------------------------------------------------------------
uint256 public treasuryTaxBps                     -> treasury tacx dalam basis points
uint256 public burnTaxBps                         -> bun=rn tax dalam basis points
uint256 public constant MAX_TOTAL_TAX_BPS = 2500  -> max 25% total tax
                                                  -> tidak bisa diubag - hard cap

BASIS POINTS:
--------------------------------------------------------------------------------------
kenapa basis points (bps) bukan persentase langsung?

kalau pakai persentase (uint256 percentage):
-> 5% tersimpan sebagai 5
-> untuk hitung: amount * 5 / 10
-> presisi buruk untuk angka kecil

kalau pakai basis points (uint256 bps):
-> 5% tersimpan sebagai 500 (500 / 10000 = 5%)
-> untuk hitung: amount * 500 / 10000
-> presisi jauh lebih baik
-> bisa represent 0.01% = 1 bps

contoh:
1 bps        = 0.01%
50 bps       = 0.5%
100 bps      = 1%
500 bps      = 5%
1000 bps     = 10%
2500 bps     = 25%
10000 bps    = 100%


ADDRESSES:
--------------------------------------------------------------------------------------
address public treasuryWallet          -> penerima treasury tax
                                       -> bisa diupdate oleh owner


EXAMPTION:
--------------------------------------------------------------------------------------
mapping(address => bool)
    private _isEXamptFromTax           -> daftar address yang bebas tax


STATISTICS (opsional tapi berguna untuk portfolio):
--------------------------------------------------------------------------------------
uint256 public totalTaxCollected       -> total tax yang sudah dipotong
uint256 public totalBurned             -> total token yang sudah dibakar
```
----

## 4. Function Yang Dibutuhkan
```bash
─────────────────────────────────────────────────────
transfer()       → akan kita override via _update
transferFrom()   → akan kita override via _update
approve()        → tidak perlu override
balanceOf()      → tidak perlu override
totalSupply()    → tidak perlu override
allowance()      → tidak perlu override

CORE OVERRIDE (yang perlu kita tulis):
─────────────────────────────────────────────────────
_update()        → PALING PENTING
                   intercept semua transfer
                   inject tax logic di sini
                   panggil super._update() untuk
                   eksekusi transfer asli

ADMIN FUNCTIONS (hanya owner):
─────────────────────────────────────────────────────
setTreasuryTax(uint256 newTaxBps)
                 → update treasury tax rate
                 → validasi: total tax tidak exceed MAX

setBurnTax(uint256 newTaxBps)
                 → update burn tax rate
                 → validasi: total tax tidak exceed MAX

setTreasuryWallet(address newWallet)
                 → update alamat treasury
                 → validasi: tidak zero address

setExemption(address account, bool exempt)
                 → tambah atau hapus dari exempt list
                 → emit event untuk transparency

pause()          → pause semua transfer
unpause()        → unpause

mint(address, uint256)
                 → cetak token baru (hanya owner)
                 → hanya saat tidak paused

VIEW FUNCTIONS (bisa dipanggil siapapun):
─────────────────────────────────────────────────────
isExemptFromTax(address)
                 → cek apakah address exempt

getTaxInfo()
                 → return semua tax config sekaligus
                 → berguna untuk frontend

calculateTax(uint256 amount)
                 → hitung berapa tax yang akan dipotong
                 → berguna untuk user sebelum transfer
```
----

## 5. Flow Diagram Trasnfer dengan Tax
Ini adalah alur eksekusi yang akan terjadi setiap kali transfer() atau transferFrom() dipanggil:
```bash
User panggil transfer(to, amount)
              │
              ▼
    OpenZeppelin ERC20._transfer()
              │
              ▼
    _update(from, to, amount) ← KITA OVERRIDE INI
              │
              ├─── Apakah contract paused?
              │         Ya  → revert EnforcedPause
              │         Tidak ↓
              │
              ├─── Apakah from ATAU to exempt dari tax?
              │         Ya  → skip tax, langsung transfer
              │         │    super._update(from, to, amount)
              │         │
              │         Tidak ↓
              │
              ├─── Hitung tax
              │    treasuryTaxAmount = amount * treasuryTaxBps / 10000
              │    burnTaxAmount     = amount * burnTaxBps / 10000
              │    totalTaxAmount    = treasuryTaxAmount + burnTaxAmount
              │    amountAfterTax    = amount - totalTaxAmount
              │
              ├─── Eksekusi transfer ke penerima
              │    super._update(from, to, amountAfterTax)
              │
              ├─── Kirim treasury tax
              │    super._update(from, treasuryWallet, treasuryTaxAmount)
              │
              ├─── Burn tax
              │    super._update(from, address(0), burnTaxAmount)
              │    → ini menurunkan totalSupply
              │
              ├─── Update statistik
              │    totalTaxCollected += totalTaxAmount
              │    totalBurned       += burnTaxAmount
              │
              └─── Emit TaxApplied event
```

### Mengapa kita panggil super._update berkali-kali?
```bash
// Cara yang salah — satu _update dengan amount penuh
// lalu coba "ambil balik" untuk tax
super._update(from, to, amount);          // transfer semua
super._update(to, treasury, taxAmount);   // ambil dari penerima???

// Ini salah karena:
// 1. Event Transfer pertama sudah emit dengan amount penuh
// 2. Penerima sudah "menerima" amount penuh
// 3. Ambil balik dari penerima bukan cara yang benar

// Cara yang benar — multiple _update dengan amount yang tepat
super._update(from, to, amountAfterTax);        // ke penerima
super._update(from, treasury, treasuryAmount);  // tax ke treasury
super._update(from, address(0), burnAmount);    // burn
// Setiap _update emit Transfer event sendiri-sendiri
// Ini yang benar secara accounting
```
----

## 6. Event yang perlu di emit
Selain event standard ERC20 (Transfer, Approval), kita tambahkan event custom untuk tax:
```bash
// Di-emit setiap kali tax dipotong dari transfer
event TaxApplied(
    address indexed from,
    address indexed to,
    uint256 amount,           // amount sebelum tax
    uint256 treasuryTax,      // berapa ke treasury
    uint256 burnTax,          // berapa yang dibakar
    uint256 amountAfterTax    // berapa yang diterima
);

// Di-emit saat tax rate diubah
event TreasuryTaxUpdated(
    uint256 oldTaxBps,
    uint256 newTaxBps
);

event BurnTaxUpdated(
    uint256 oldTaxBps,
    uint256 newTaxBps
);

// Di-emit saat treasury wallet diubah
event TreasuryWalletUpdated(
    address indexed oldWallet,
    address indexed newWallet
);

// Di-emit saat exemption diubah
event ExemptionUpdated(
    address indexed account,
    bool isExempt
);
```
----

## 7. Error yang dibutuhkan
```bash
// Tax rate melebihi maximum
error TaxTooHigh(
    uint256 requested,    // tax yang diminta
    uint256 maximum       // maximum yang diizinkan
);

// Treasury wallet tidak valid
error InvalidTreasuryWallet();

// Address tidak valid (zero address)
error InvalidAddress();

// Tidak ada perubahan yang terjadi
error NoChangeDetected();
```