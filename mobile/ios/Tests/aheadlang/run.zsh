#!/bin/zsh
# Regression guard: BUG-11. SpeechAhead on Automatic (fallback "en", as the phone passes) must hear each recording in
# its own language. Recordings are made with `say` (fixtures, no copyrighted audio). Outside the sandbox.
set -e
root=${0:A:h:h:h:h:h}; d=$(mktemp -d)
say -v "Eddy (French (France))" -o $d/fr.aiff "La cour a jugé que le contrat était nul. Néanmoins, le demandeur a fait appel devant la cour supérieure, en soutenant que le juge avait mal lu la loi."
say -v "Linh (Vietnamese (Vietnam))" -o $d/vi.aiff "Tòa án đã phán quyết rằng hợp đồng vô hiệu. Tuy nhiên, nguyên đơn đã kháng cáo lên tòa án cấp cao hơn."
say -v Samantha -o $d/en.aiff "The court held that the contract was void. Nevertheless, the plaintiff appealed to the higher court, arguing that the judge had misread the statute."
xcrun swiftc -O $root/shared/speechcore.swift $root/mobile/ios/Tests/aheadlang/main.swift -o $d/aheadlang
fail=0
for l in fr vi en; do $d/aheadlang $d/$l.aiff $l > $d/$l.out 2>&1 || fail=1; echo "== $l"; tail -3 $d/$l.out; done
rm -rf $d
exit $fail
