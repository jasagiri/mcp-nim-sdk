| claim | verdict | | layer | text | evidence |
|---|---|---|---|---|---|
| SPEC-01 | holds | required | specification | specs/ に宣言した仕様 ID のすべてに、それを確かめる外部仕様テストがある | 1 for, 0 against |
| INP-01 | holds | required | input | 相手が選んだ文字列を読む 10 の入口 (tests/fuzz/targets.nim) は、種と、ファジングが見つけた入力で、文書にした拒否のほかに何も上げない | 1 for, 0 against |
| INP-02 | nobody checked | required | input | ファジングの入口の一覧を、書いた者以外が見直した | 0 for, 0 against |
| INP-03 | nobody checked | required | input | 一覧に無い入口 (HTTP の要求と応答の読み取り、JSON-RPC の振り分け、OAuth のメタデータ文書、stdio の行) もファジングした | 0 for, 0 against |
| INP-04 | nobody checked | required | input | 公開の前に、入口を libFuzzer で長く掘った | 0 for, 0 against |
| DEP-01 | does not hold | required | dependency | nimble が求める Nim の下限は、base64.decode の欠陥 (nim-lang/Nim#25530) を直した版以上である | 0 for, 1 against |
| DEP-02 | holds | required | dependency | base64 を復号する 4 か所は、相手が選んだ文字列を、形を確かめるか署名を確かめてから復号する | 2 for, 0 against |
| DEP-03 | nobody checked | optional | dependency | コンパイラと依存の版を、既知の欠陥の一覧 (nim-advisory-check) と突き合わせた | 0 for, 0 against |
| SEC-01 | the evidence disagrees | required | design | 2026-10-06 のセキュリティレビューの指摘 (Critical 1、High 4、Medium 6、Low 6) のそれぞれに、再現するテストと修正がある | 1 for, 1 against |
| SEC-02 | nobody checked | required | design | セキュリティレビューを、実装した者 (このエージェントのチーム) 以外が行った | 0 for, 0 against |
| SEC-03 | holds | required | design | https の接続は、証明書の名前を接続先のホスト名と照合する | 1 for, 0 against |
| OPS-01 | does not hold | required | operation | 公開した HTTP サーバーは、要求を送り終えない相手に接続を占有され続けない | 0 for, 1 against |
| VER-01 | nobody checked | required | release | 公開するコミットで、5 つの版それぞれを既定にした全テストが通る | 0 for, 0 against |
| VER-01a | holds | required | release | 実装を最後に通しで確かめたコミットで、5 版とも失敗 0・警告 0 だった | 1 for, 0 against |
| VER-01b | nobody checked | required | release | そのあとの修正 (HTTP クライアントの 2 件、JSON Schema の検証器) を含む公開するコミットで、通しを取り直した | 0 for, 0 against |
| VER-02 | nobody checked | required | release | 版ごとのタグを展開したディレクトリで、nimble test と examples のコンパイルが通る | 0 for, 0 against |
| IOP-01 | nobody checked | required | interoperability | 公開するコミットで、5 つの版それぞれが公式の Python SDK・TypeScript SDK と stdio と HTTP で接続できる | 0 for, 0 against |
| IOP-01a | holds | required | interoperability | 2026-10-06 のコミットで、総当たり 312 行がすべて期待どおりだった | 1 for, 0 against |
| IOP-01b | nobody checked | required | interoperability | 公開するコミットで総当たりを測り直した | 0 for, 0 against |
| CNF-01 | nobody checked | required | interoperability | 公開するコミットで、公式の適合性テストに不合格が無い | 0 for, 0 against |
| CNF-01a | holds | required | interoperability | 2026-10-06 のコミットで、サーバー検査とクライアント検査に不合格が無かった (2024-11-05 は検査が無い) | 1 for, 0 against |
| CNF-01b | nobody checked | required | interoperability | 公開するコミットで適合性テストを測り直した | 0 for, 0 against |
| REV-01 | nobody checked | required | review | 変異検査で外部仕様テストの検出力を測り、公開するコミットに、理由の無い生き残りが無い | 0 for, 0 against |
| REV-01a | holds | required | review | 36a4c8a5 と 7d32c165 で測った本線の 27 ジョブの生き残り 1,387 件すべてに、分類と理由がある | 1 for, 0 against |
| REV-01b | nobody checked | required | review | 測定のあとに実装が変わった 16 ジョブを測り直し、新しい生き残りを分類した | 0 for, 0 against |
| DOWN-01 | nobody checked | optional | release | この SDK を使う下流のパッケージ (社内のもの) が、公開するコミットでコンパイルできる | 0 for, 0 against |

Not releasable: a required claim does not hold, is contradicted, or was not checked.

Nobody checked: INP-02, INP-03, INP-04, DEP-03, SEC-02, VER-01, VER-01b, VER-02, IOP-01, IOP-01b, CNF-01, CNF-01b, REV-01, REV-01b, DOWN-01

The evidence disagrees: SEC-01

Does not hold: DEP-01, OPS-01
