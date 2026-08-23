/* The DRIVER sections: everything a command list drives. */

package plugintest

import "testing"

var driverSections = []string{
	"lifecycle", "order", "point", "export", "depend",
	"declare", "state", "resource", "nest", "trace", "apply", "error",
}

func TestDriverSections(t *testing.T) {
	for _, name := range driverSections {
		groups, err := Section(name)
		if nil != err {
			t.Fatalf("%s: %v", name, err)
		}

		t.Run(name+": every entry carries cmd", func(t *testing.T) {
			for _, g := range Groups(groups) {
				for i, e := range groups[g] {
					if nil == e.Cmd {
						t.Errorf("driver entry without cmd: %s", Label(g, i, e))
					}
				}
			}
		})

		for _, g := range Groups(groups) {
			name, g := name, g
			t.Run(name+"/"+g, func(t *testing.T) {
				for i, e := range groups[g] {
					why := Check(e, func(en Entry) (any, error) { return Drive(en.Cmd) })
					if "" != why {
						t.Errorf("%s: %s", Label(g, i, e), why)
					}
				}
			})
		}
	}
}
