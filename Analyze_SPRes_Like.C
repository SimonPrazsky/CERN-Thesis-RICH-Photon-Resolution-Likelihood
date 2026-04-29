#include <TTree.h>
#include <TCanvas.h>
#include <TH1F.h>
#include <TError.h>
#include <cstdio>
#include <stdatomic.h>

void hist(const char* filename = "histo00.root", float mom_low = 55.0, float mom_high = 65.0) {
    TFile* f = TFile::Open(filename, "READ");
    if (!f || f->IsZombie()) {
        Error("rich_cmom", "Cannot open file: %s", filename);
        return;
    }

    TTree* RICH = nullptr;
    f->GetObject("RICH/NTUP/111", RICH);
    if (!RICH) {
        Error("rich_cmom", "TTree RICH/NTUP/111 not found");
        return;
    }

    // Declaration of leaf types
    Float_t         Header_Run;
    Float_t         Header_Ev;
    Float_t         Header_Index;
    Int_t           nTracks;
    Float_t         xIn[30];   //[nTracks]  position, x, y, z
    Float_t         yIn[30];   //[nTracks]
    Float_t         zIn[30];   //[nTracks]
    Float_t         tgX[30];   //[nTracks]  dx/dz
    Float_t         tgY[30];   //[nTracks]  dy/dz
    Float_t         cmom[30];   //[nTracks] charge*mom
    Float_t         zHx0[30];   //[nTracks]  part->zHelix0 + chiSq*100000
    Float_t         zHx1[30];   //[nTracks]  part->zHelix1 + nClus*100000
    // --- rings  ------------------
    Int_t           nRings;
    Float_t         theta[30];   //[nRings]
    Int_t           cPaDe[30];   //[nRings]
    Float_t         xPaDe[30];   //[nRings]
    Float_t         yPaDe[30];   //[nRings]
    Int_t           nPhoRing[30];   //[nRings]  number of photons in the ring
    Int_t           nPhoBkx[30];   //[nRings]
    // --- Photons ------------------
    Int_t           nPhotons;
    Float_t         the[10000];   //[nPhotons] posotive for PMT, negative for APV detector
    Float_t         phi[10000];   //[nPhotons]
    Float_t         PH[10000];   //[nPhotons]  ??
    Int_t           cath[10000];   //[nPhotons]cathode id of the corresponding photon
    Float_t         xc[10000];   //[nPhotons]
    Float_t         yc[10000];   //[nPhotons]
    Int_t           nPads[10000];   //[nPhotons]
    Float_t         paPH[10000];   //[nPhotons]   ??
    // --- likelihood calculation
    Int_t           nLike;
    Float_t         likeBkg[30];   //[nLike]  background assumption
    Float_t         likePi[30];   //[nLike]  pion assumption
    Float_t         likeKa[30];   //[nLike]  kaon
    Float_t         likePr[30];   //[nLike] proton
    Float_t         dLiDnPi[30];   //[nLike]
    Float_t         dLiDnKa[30];   //[nLike]
    Float_t         dLiDnPr[30];   //[nLike]
    Float_t         theLike[30];   //[nLike] theta from Max likelihood
    Float_t         theRec[30];   //[nLike]  reconstructed theta
    Float_t         nPhoLk[30];   //[nLike] number of photons in the ring for likelihood calculation
    Float_t         theFit[30];   //[nLike] theta from the fit
    Float_t         chiRing[30];   //[nLike]
    Float_t         chiPi[30];   //[nLike]
    Float_t         chiKa[30];   //[nLike]
    Float_t         chiPr[30];   //[nLike]
    Float_t         likeEl[30];   //[nLike] electron
    Float_t         likeMu[30];   //[nLike] muon
    Float_t         dLiDnEl[30];   //[nLike]
    Float_t         dLiDnMu[30];   //[nLike]
    Float_t         chiEl[30];   //[nLike]
    Float_t         chiMu[30];   //[nLike]

    Int_t           Phys_kEvGood;
    Int_t           Phys_kMuPart;
    Float_t         Phys_zVertex;
    Float_t         Phys_phiMass;
    //RICH->SetBranchAddress("Header", &Header_Run);
    RICH->SetBranchAddress("nTracks", &nTracks);
    RICH->SetBranchAddress("xIn", xIn);
    RICH->SetBranchAddress("yIn", yIn);
    RICH->SetBranchAddress("zIn", zIn);
    RICH->SetBranchAddress("tgX", tgX);
    RICH->SetBranchAddress("tgY", tgY);
    RICH->SetBranchAddress("cmom", cmom);
    //RICH->SetBranchAddress("zHx0", zHx0);
    //RICH->SetBranchAddress("zHx1", zHx1);
    RICH->SetBranchAddress("nRings", &nRings);
    RICH->SetBranchAddress("theta", theta);
    RICH->SetBranchAddress("cPaDe", cPaDe);
    RICH->SetBranchAddress("xPaDe", xPaDe);
    RICH->SetBranchAddress("yPaDe", yPaDe);
    RICH->SetBranchAddress("nPhoRing", nPhoRing);
    //RICH->SetBranchAddress("nPhoBkx", nPhoBkx);
    RICH->SetBranchAddress("nPhotons", &nPhotons);
    RICH->SetBranchAddress("the", the);
    RICH->SetBranchAddress("phi", phi);
    RICH->SetBranchAddress("PH", PH);
    RICH->SetBranchAddress("cath", cath);
    RICH->SetBranchAddress("xc", xc);
    RICH->SetBranchAddress("yc", yc);
    RICH->SetBranchAddress("nPads", nPads);
    //RICH->SetBranchAddress("paPH", paPH);
    RICH->SetBranchAddress("nLike", &nLike);
    RICH->SetBranchAddress("likeBkg", likeBkg);
    RICH->SetBranchAddress("likePi", likePi);
    RICH->SetBranchAddress("likeKa", likeKa);
    RICH->SetBranchAddress("likePr", likePr);
    RICH->SetBranchAddress("likeEl", likeEl);
    RICH->SetBranchAddress("likeMu", likeMu);

    // create histograms for Single Photon Resolution map
    TH2D* SPR_sigma = new TH2D("SPR_sigma", "h_sigma;std dev;Entries", 100, -1500, 1500, 100, -1500, 1500);
    TH2I* SPR_n = new TH2I("SPR_n", "h_nphot;nPhotons;Entries", 100, -1500, 1500, 100, -1500, 1500);
    // create histograms for pion/kaon likelihood ratio map
    TH2D* L_pi_ka = new TH2D("L_pi_ka", "h_pi_ka;likelihood ratio;Entries", 100, -1500, 1500, 100, -1500, 1500);
    TH2I* L_n = new TH2I("L_n", "h_nphot;nPhotons;Entries", 100, -1500, 1500, 100, -1500, 1500);

    TH1I* hdebug = new TH1I("hdebug", "Event cut debug;cut_no;Entries", 6, 0, 6);
    TH1I* hdebug_ntracks = new TH1I("hdebug_ntracks", "Number of tracks/event;Number of tracks in event;Entries", 20, 0, 20);
    long totalTracks = 0;
    long selectedTracks = 0;
    long totalCutTracks = 0;
    // 0 - zero tracks -- half of all       OK expected
    // 1 - noisy events -- cuts above 300 threshold
    // 2 - too few photons -- ~5%           ?
    // 3 - momentum cut -- most tracks      OK expected
    // 4 - negative photon indeces ~0.5%    need to investigate -- ISSUE FIXED
    // 5 - sigma = 0.0

    int nEntries = RICH->GetEntries();
    for (int i = 0; i < nEntries; ++i) {
        if (i % 20000 == 0) printf("Entry %d/%d\n", i, nEntries);
        RICH->GetEntry(i);
        hdebug_ntracks->Fill(nTracks);
        //printf("\n-------------------------\nEntry %d:\tnTracks = %d\tnRings = %d\n", i, nTracks, nRings);

        // Cut events with zero tracks
        if (nTracks == 0) { //hdebug->Fill(0);
            continue;
        }

        totalTracks += nTracks;
        int stdev_skipped = 0;  // counter for tracks that were skipped due to std dev = 0
        int negative_indeces_skipped = 0;  // sanity check - counter for tracks that were skipped due to negative indeces

        // Photon indices
        int photon_start_id[350];
        int photon_end_id[350];
        for (int ii = 0; ii < 350; ++ii) {
            photon_start_id[ii] = -999;
            photon_end_id[ii] = -999;
        }
        int last_valid_j = -1;

        for (auto j = 0; j < nTracks; ++j) {
            // Filter out too noisy events
            if (nPhotons > 300) {   // Doesn't cut anything for treshold >=300 -- number of photons per track is probably limited
                hdebug->Fill(1);
                continue;
            }
            if (nPhoRing[j] < 3) {  // Filtering out rings with less than 3 photons because they yield sigma ~= 0.8 mrad
                //hdebug->Fill(2);
                continue;     // should remove tracks that return sigma = 0.0 - CHECK IT
            }

            // --- Momentum cut ---
            auto momentum = fabs(cmom[j]);
            if (momentum < mom_low || momentum > mom_high) {
                //hdebug->Fill(3);
                continue;
            }

            // --- Single Photon Resolution map ---

            if (last_valid_j == -1) {
                photon_start_id[j] = 0;
            } else {
                photon_start_id[j] = photon_end_id[last_valid_j] + 1;
            }
            photon_end_id[j] = photon_start_id[j] + nPhoRing[j] - 1;

            // Negative indeces check
            if (photon_start_id[j] < 0 || photon_end_id[j] < 0) {
                hdebug->Fill(4);
                printf("Event = %d\t Track j = %d\t Photon index range: %d-%d\n", i, j, photon_start_id[j], photon_end_id[j]);
                continue;
            }
            //printf("Photon index range: %d-%d\n", photon_start_id[j], photon_end_id[j]);
            auto histo_theta_residual = new TH1F("histo_theta_residual", "histo_theta_residual;theta residual;Entries", 100, -10, 10);
            for (auto k = photon_start_id[j]; k <= photon_end_id[j]; ++k) {
                auto theta_residual = the[k] - theta[j];
                histo_theta_residual->Fill(theta_residual);
                //printf("\tcoordinates: x = %f\ty = %f\n", xc[k], yc[k]);
            }
            auto std_dev = histo_theta_residual->GetStdDev();
            //histo_theta_residual->Draw();
            delete histo_theta_residual;    // must be commented out if one wants to see the histogram
            if (std_dev == 0.0) { hdebug->Fill(5); continue; }
            printf("std_dev = %f\tnPhoRing = %d\n", std_dev, nPhoRing[j]);
            for (auto k = photon_start_id[j]; k <= photon_end_id[j]; ++k) {
                SPR_sigma->Fill(xc[k], yc[k], std_dev);
                SPR_n->Fill(xc[k], yc[k]);
            }

            // --- Pion/Kaon Likelihood ratio map ---
            auto pi_ka_ratio = likePi[j] / likeKa[j];
            L_pi_ka->Fill(xPaDe[j], yPaDe[j], pi_ka_ratio);
            L_n->Fill(xPaDe[j], yPaDe[j]);

            selectedTracks++;
        }
        //printf("Std dev skipped: \t%d\nNegative indeces skipped: \t%d\nnPhotons = %d\n-------------------------\n", stdev_skipped, negative_indeces_skipped, nPhotons);
    }
    totalCutTracks = totalTracks - hdebug->Integral();

    // get mean value in z-axis for entire detector
    double SPR_sigma_mean = SPR_sigma->Integral()/SPR_n->Integral();
    //printf("SPR sigma mean: %f\n", SPR_sigma_mean)
    TString title = "SPR sigma mean: " + TString::Format("%f", SPR_sigma_mean);
    SPR_sigma->SetTitle(title);

    // Average out histograms
    SPR_sigma->Divide(SPR_n);
    L_pi_ka->Divide(L_n);

    // Draw histograms
    // create canvas and divide it (to show histograms next to each other)
    TCanvas* c1 = new TCanvas("c1", "c1", 1200, 600);
    c1->Divide(2, 1);
    c1->cd(1);
    SPR_sigma->Draw("colz");
    c1->cd(2);
    L_pi_ka->Draw("colz");
    c1->Update();

    TCanvas* c2 = new TCanvas("c2", "c2", 1200, 600);
    //gStyle->SetOptLogy();
    c2->Divide(2, 1);
    c2->cd(1);
    TString title2 = "Selected tracks: " + std::to_string(selectedTracks) + " / " + std::to_string(totalTracks) + " = " + std::to_string(static_cast<double>(selectedTracks) / totalTracks) + "\tnEntries: " + std::to_string(nEntries);
    hdebug->SetTitle(title2);
    hdebug->Draw();
    c2->cd(2);
    hdebug_ntracks->Draw();
    //c2->Update();


    // Build output file name
    TString outfilename = TString("SPRL_") + gSystem->BaseName(filename);
    outfilename.ReplaceAll(".root", "");
    // Save canvas to file
    c1->SaveAs(outfilename + ".png");
    // Save histograms to file
    TFile* outfile = new TFile(outfilename + ".root", "RECREATE");
    SPR_sigma->Write();
    L_pi_ka->Write();
    outfile->Close();
}

